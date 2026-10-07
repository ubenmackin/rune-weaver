// Rune Weaver Core Tests — Per-host egress scoping for shell and desktop URL-typing.
//
// Purpose: pin the host-scoped network contract shared by sandboxed shells and
// desktop typing — validated host declarations, blanket-allow Seatbelt text
// with supervisor string screening, supervisor cross-checks that refuse
// undeclared dials, and approval surfaces that name destinations instead of
// a blank check. The screening is best-effort: it sees explicit URLs,
// schemeless host text, and typed URLs, but misses dials that never surface
// as recognizable host strings (non-URL spellings and encoded or obfuscated
// forms), so a screened pass narrows the dial surface without proving
// no-egress.
// Scope: Seatbelt profile text, supervisor host comparison, bash.exec argument
// handling and screening, plus desktop bridge parity through the same checker.
// Architectural role: executable specification for the posture where the
// sandbox stays blanket-allow and the supervisor plus approval card agree
// on hosts (undeclared deny, declared-plus-policy-allowed allow).

import Foundation
@testable import RuneWeaverCore
@testable import RuneWeaverTools
import Testing

@Suite("Egress Scoping")
struct EgressScopingTests {
    /// Builds a supervisor over a throwaway verified policy with task-scoped DNS.
    private func withSupervisor(
        policy: SecurityPolicy,
        dnsProof: @escaping @Sendable (String) -> [String] = { _ in ["93.184.216.34"] },
        _ body: (OutboundEgressSupervisor) async throws -> Void
    ) async throws {
        try await ApiSSRFGuard.$taskTestDNSResolver.withValue(dnsProof) {
            let store = PolicyStore(fileURL: URL(fileURLWithPath: "/tmp/test-egress-scope-\(UUID().uuidString).toml"))
            await store.update(policy)
            let supervisor = OutboundEgressSupervisor(
                policyStore: store,
                secrets: SecretsManager(inMemory: true),
                browserConfig: BrowserConfig()
            )
            try await body(supervisor)
        }
    }

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

    /// Builds a hermetic bash tool rooted in isolated scratch with a stubbed seam.
    ///
    /// The isolated root forces the host fallback so turns never create
    /// containers, while the stubbed seam keeps any isolated-tier probe hermetic.
    private func makeHermeticBashTool(
        bashConfig: BashConfig,
        supervisor: OutboundEgressSupervisor?,
        base: URL
    ) -> BashTool {
        let root = base.appendingPathComponent("ws", isDirectory: true)
        let store = WorkspaceStore(config: WorkspaceConfig(), rootURL: root)
        let (seam, _) = ContainerSeam.hermetic()
        return BashTool(
            bashConfig: bashConfig,
            allowUnsandboxedFallback: true,
            egressSupervisor: supervisor,
            workspaceConfig: WorkspaceConfig(),
            workspaceStore: store,
            containers: seam
        )
    }

    private func allowEchoConfig() -> BashConfig {
        BashConfig(
            defaultAction: .ask,
            rules: [
                BashRule(pattern: "*", action: .ask),
                BashRule(pattern: "echo", action: .allow)
            ]
        )
    }

    // MARK: - Profile text

    @Test
    func `Declared hosts keep blanket allow with supervisor as per-host gate`() {
        let builder = SeatbeltProfileBuilder(
            allowedReadPaths: ["/tmp/app"],
            allowedWritePaths: ["/tmp/app"],
            allowNetwork: true,
            allowedEgressHosts: ["api.example.com", "93.184.216.34"]
        )
        let profile = builder.buildProfile()

        // Per-host SBPL is not expressible on current macOS (the kernel only
        // accepts `localhost` or `*` as IP, so hostnames reject as kleene
        // star), so declared hosts keep the blanket allow and the supervisor
        // remains the per-host enforcement point through best-effort string
        // screening (undeclared deny, declared-plus-policy-allowed allow).
        // Narrowing declared hosts to deny-all would grant less capability
        // than declaring nothing and leave `network_hosts` unusable.
        #expect(profile.contains("(allow network*)"))
        #expect(!profile.contains("(deny network*)"))
        #expect(!profile.contains("network-outbound"))
        #expect(!profile.contains("remote tcp"))
        #expect(!profile.contains("remote ip"))
        #expect(!profile.contains(":*\""))
        #expect(profile.contains("(deny default)"))
    }

    @Test
    func `Empty hosts preserve prior blanket behavior`() {
        let allowed = SeatbeltProfileBuilder(
            allowedReadPaths: ["/tmp/app"],
            allowedWritePaths: ["/tmp/app"],
            allowNetwork: true
        ).buildProfile()
        #expect(allowed.contains("(allow network*)"))
        #expect(!allowed.contains("(deny network*)"))

        let denied = SeatbeltProfileBuilder(
            allowedReadPaths: ["/tmp/app"],
            allowedWritePaths: ["/tmp/app"],
            allowNetwork: false,
            allowedEgressHosts: ["api.example.com"]
        ).buildProfile()
        #expect(denied.contains("(deny network*)"))
        #expect(!denied.contains("api.example.com"))
    }

    @Test
    func `Declared hosts keep blanket allow without scoped emission`() {
        // Per-host address filters are unverified on current macOS, so the
        // builder keeps the blanket allow and relies on supervisor string
        // screening instead of emitting an unscoped deny it cannot express.
        let builder = SeatbeltProfileBuilder(
            allowedReadPaths: ["/tmp/app"],
            allowedWritePaths: ["/tmp/app"],
            allowNetwork: true,
            allowedEgressHosts: ["api.example.com"]
        )
        let profile = builder.buildProfile()
        #expect(profile.contains("(allow network*)"))
        #expect(!profile.contains("(deny network*)"))
        #expect(!profile.contains("(allow network-outbound"))
    }

    @Test
    func `Blanket profile pairs with supervisor host gate`() async throws {
        // The profile stays blanket-allow (per-host SBPL inexpressible: the
        // kernel only accepts `localhost` or `*` as IP, so hostnames reject as
        // kleene star), so the supervisor's declared-host check is the
        // per-host enforcement point: a declared-plus-policy-allowed dial
        // passes while an undeclared dial denies. Screening stays
        // best-effort — explicit URLs, schemeless host text, and typed URLs
        // screen, while non-URL spellings and encoded or obfuscated forms
        // bypass string matching without breaking this gate.
        let profile = SeatbeltProfileBuilder(
            allowedReadPaths: ["/tmp/app"],
            allowedWritePaths: ["/tmp/app"],
            allowNetwork: true,
            allowedEgressHosts: ["api.example.com"]
        ).buildProfile()
        #expect(profile.contains("(allow network*)"))
        #expect(!profile.contains("(deny network*)"))
        #expect(!profile.contains("network-outbound"))
        let policy = SecurityPolicy(
            network: NetworkEgressPolicy(mode: .allowlistOnly, allowedDomains: ["api.example.com"])
        )
        try await withSupervisor(policy: policy) { supervisor in
            #expect(supervisor.checkHosts(["api.example.com"], against: ["api.example.com"]).isEmpty)
            #expect(supervisor.checkHosts(["evil.example.com"], against: ["api.example.com"]) == ["evil.example.com"])
        }
    }

    @Test
    func `Invalid declared hosts keep blanket allow with upstream validation`() {
        // Host validity is enforced upstream by `checkedDeclaredHosts` in the
        // calling tool; the sandbox itself stays blanket-allow so an invalid
        // declaration never narrows the profile below the empty-host posture.
        let builder = SeatbeltProfileBuilder(
            allowedReadPaths: ["/tmp/app"],
            allowedWritePaths: ["/tmp/app"],
            allowNetwork: true,
            allowedEgressHosts: ["not a host!!", "https://api.example.com/x"]
        )
        let profile = builder.buildProfile()
        #expect(profile.contains("(allow network*)"))
        #expect(!profile.contains("(deny network*)"))
    }

    @Test
    func `Host validation caps dedupes and normalizes`() {
        let hosts = SeatbeltProfileBuilder.sanitizedEgressHosts([
            "API.Example.COM",
            "api.example.com",
            " 93.184.216.34 ",
            "localhost",
            "*.example.com",
            "api.example.com:443",
            "https://evil.com/x",
            "",
            "not a host"
        ])
        #expect(hosts.contains("api.example.com"))
        #expect(hosts.contains("93.184.216.34"))
        #expect(hosts.contains("localhost"))
        #expect(!hosts.contains("*.example.com"))
        #expect(!hosts.joined(separator: " ").contains("443"))
        #expect(hosts.count == Set(hosts).count)

        var eleven: [String] = []
        for index in 0 ..< 11 {
            eleven.append("host\(index).example.com")
        }
        #expect(SeatbeltProfileBuilder.sanitizedEgressHosts(eleven).count == SeatbeltProfileBuilder.maxEgressHosts)
    }

    @Test
    func `Scoped profile parses under sandbox-exec when available`() throws {
        let sandboxExecURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        guard FileManager.default.isExecutableFile(atPath: sandboxExecURL.path) else {
            return
        }
        // Blanket-allow evidence: the declared-host profile must be accepted
        // by the kernel parser. Per-host `remote tcp` with hostnames rejects
        // as kleene star, so the form carries no `remote` filters at all and
        // the supervisor screens declared hosts instead.
        let profile = SeatbeltProfileBuilder(
            allowedReadPaths: ["/bin", "/usr"],
            allowedWritePaths: ["/tmp", "/private/tmp"],
            allowNetwork: true,
            allowedEgressHosts: ["api.example.com"]
        ).buildProfile()
        #expect(profile.contains("(allow network*)"))
        #expect(!profile.contains("(deny network*)"))
        #expect(!profile.contains("network-outbound"))
        #expect(!profile.contains("remote tcp"))
        #expect(!profile.contains("remote ip"))
        #expect(!profile.contains(":*\""))
        let process = Process()
        process.executableURL = sandboxExecURL
        process.arguments = ["-p", profile, "/usr/bin/true"]
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    // MARK: - Supervisor host scoping

    @Test
    func `Supervisor reports screened hosts missing a declaration`() async throws {
        let policy = SecurityPolicy(network: NetworkEgressPolicy(mode: .unrestricted))
        try await withSupervisor(policy: policy) { supervisor in
            let undeclared = supervisor.checkHosts(
                ["api.example.com", "evil.example.com"],
                against: ["api.example.com"]
            )
            #expect(undeclared == ["evil.example.com"])
            #expect(supervisor.checkHosts([], against: []).isEmpty)
            #expect(supervisor.checkHosts(["Api.Example.COM"], against: ["api.example.com"]).isEmpty)
            #expect(supervisor.checkHosts(["evil.example.com"], against: []).count == 1)
        }
    }

    @Test
    func `Declared host passes policy while undeclared denies before policy`() async throws {
        let policy = SecurityPolicy(
            network: NetworkEgressPolicy(mode: .allowlistOnly, allowedDomains: ["api.example.com"])
        )
        try await withSupervisor(policy: policy) { supervisor in
            // Declared and allowlisted: the full gate allows.
            let declaredURL = try #require(URL(string: "https://api.example.com/data"))
            switch await supervisor.validate(url: declaredURL, method: "GET", headers: [:]) {
            case .allowed:
                break
            case let .denied(reason), let .unlistedDomain(_, reason):
                Issue.record("Expected declared host to pass policy, got: \(reason)")
            }
            // Undeclared fails at the host check even though an unrestricted
            // policy would otherwise allow it; enforcement order matters and
            // the pure helper needs no policy to prove the gap.
            let missing = supervisor.checkHosts(["evil.example.com"], against: ["api.example.com"])
            #expect(missing == ["evil.example.com"])
        }
    }

    // MARK: - Bash tool

    @Test
    func `Bash rejects network_hosts over the cap and malformed entries`() async throws {
        let policy = SecurityPolicy(network: NetworkEgressPolicy(mode: .unrestricted))
        try await withSupervisor(policy: policy) { supervisor in
            // Hermetic stub keeps the suite container-free; validation parks before any spawn.
            let (hermeticSeam, _) = ContainerSeam.hermetic()
            let tool = BashTool(bashConfig: allowEchoConfig(), allowUnsandboxedFallback: true, egressSupervisor: supervisor, containers: hermeticSeam)
            var eleven: [String] = []
            for index in 0 ..< 11 {
                eleven.append("host\(index).example.com")
            }
            let elevenJSON = try #require(
                String(
                    data: JSONSerialization.data(withJSONObject: ["command": "echo hi", "request_network": true, "network_hosts": eleven]),
                    encoding: .utf8
                )
            )
            let elevenOut = try await tool.execute(
                input: ToolInput(toolName: "bash.exec", argumentsJSON: elevenJSON),
                context: ToolContext(conversationID: UUID(), approved: true)
            )
            #expect(elevenOut.isError)
            #expect(elevenOut.content.contains("network_hosts"))

            let badOut = try await tool.execute(
                input: ToolInput(toolName: "bash.exec", argumentsJSON: #"{"command":"echo hi","request_network":true,"network_hosts":["not a host!!"]}"#),
                context: ToolContext(conversationID: UUID(), approved: true)
            )
            #expect(badOut.isError)
            #expect(badOut.content.contains("network_hosts"))
        }
    }

    @Test
    func `Bash denies undeclared dials and audits the refusal`() async throws {
        // Unrestricted policy proves the declared-hosts gate denies on its
        // own: the supervisor would allow the host, but the missing
        // declaration refuses first and names the offender.
        let policy = SecurityPolicy(network: NetworkEgressPolicy(mode: .unrestricted))
        try await withSupervisor(policy: policy) { supervisor in
            // Hermetic stub keeps the suite container-free; screening parks before any spawn.
            let (hermeticSeam, _) = ContainerSeam.hermetic()
            let tool = BashTool(bashConfig: allowEchoConfig(), allowUnsandboxedFallback: true, egressSupervisor: supervisor, containers: hermeticSeam)
            let output = try await tool.execute(
                input: ToolInput(
                    toolName: "bash.exec",
                    argumentsJSON: #"{"command":"echo https://evil.example.com/data","request_network":true,"network_hosts":["api.example.com"]}"#
                ),
                context: ToolContext(conversationID: UUID(), approved: true)
            )
            #expect(output.isError)
            #expect(output.content.contains("undeclared"))
            #expect(output.content.contains("evil.example.com"))
            #expect(output.content.contains("\"denied\":true"))
        }
    }

    @Test
    func `Bash allows declared host when policy permits`() async throws {
        let policy = SecurityPolicy(
            network: NetworkEgressPolicy(mode: .allowlistOnly, allowedDomains: ["api.example.com"])
        )
        try await withSupervisor(policy: policy) { supervisor in
            // Hermetic execution stays on the host fallback under isolated
            // scratch so the full suite creates zero containers.
            let base = try makeHermeticWorkspaceBase(label: "egress-allow")
            defer { removeHermeticWorkspaceBase(base) }
            let tool = makeHermeticBashTool(bashConfig: allowEchoConfig(), supervisor: supervisor, base: base)
            let sessionID = UUID()
            let output = try await tool.execute(
                input: ToolInput(
                    toolName: "bash.exec",
                    argumentsJSON: #"{"command":"echo https://api.example.com/data","request_network":true,"network_hosts":["api.example.com"]}"#
                ),
                context: ToolContext(conversationID: sessionID, approved: true)
            )
            #expect(!output.isError)
            #expect(output.content.contains("api.example.com"))
        }
    }

    @Test
    func `Bash request_network approval names declared hosts`() async throws {
        let policy = SecurityPolicy(network: NetworkEgressPolicy(mode: .unrestricted))
        try await withSupervisor(policy: policy) { supervisor in
            // Hermetic stub keeps the suite container-free; approval parks before any spawn.
            let (hermeticSeam, _) = ContainerSeam.hermetic()
            let tool = BashTool(bashConfig: allowEchoConfig(), allowUnsandboxedFallback: true, egressSupervisor: supervisor, containers: hermeticSeam)
            let output = try await tool.execute(
                input: ToolInput(
                    toolName: "bash.exec",
                    argumentsJSON: #"{"command":"echo hello","request_network":true,"network_hosts":["api.example.com","files.example.com"]}"#
                ),
                context: ToolContext(conversationID: UUID())
            )
            #expect(output.isError)
            #expect(output.content.contains("\"approvalRequired\":true"))
            #expect(output.content.contains("api.example.com"))
            #expect(output.content.contains("files.example.com"))
        }
    }

    @Test
    func `Bash description documents host-scoped network`() {
        // Hermetic stub keeps the suite container-free; description never spawns.
        let (hermeticSeam, _) = ContainerSeam.hermetic()
        let tool = BashTool(bashConfig: BashConfig(), containers: hermeticSeam)
        #expect(tool.description.contains("network_hosts"))
        #expect(tool.inputSchema.rawValue.contains("network_hosts"))
    }

    // MARK: - Desktop parity

    @Test
    func `Desktop bridge denies undeclared typed hosts through the shared check`() async throws {
        let policy = SecurityPolicy(network: NetworkEgressPolicy(mode: .unrestricted))
        try await withSupervisor(policy: policy) { supervisor in
            let bridge = DesktopControlBridge(
                accessibilityAccess: { true },
                egressSupervisor: supervisor
            )
            let actions = [DesktopAction.typeText(text: "open https://evil.example.com/data now")]
            do {
                _ = try await bridge.executeBatch(
                    actions: actions,
                    scaleX: 1.0,
                    scaleY: 1.0,
                    blockedApps: [],
                    sessionID: UUID(),
                    declaredHosts: ["api.example.com"]
                )
                Issue.record("Expected undeclared typed host to deny")
            } catch let error as DesktopControlError {
                switch error {
                case let .blockedURL(host, _, reason):
                    #expect(host.contains("evil.example.com"))
                    #expect(reason.contains("declared"))
                default:
                    Issue.record("Expected blockedURL, got \(error)")
                }
            }
        }
    }

    @Test
    func `Desktop bridge passes declared host screening like shell`() async throws {
        let policy = SecurityPolicy(
            network: NetworkEgressPolicy(mode: .allowlistOnly, allowedDomains: ["api.example.com"])
        )
        try await withSupervisor(policy: policy) { supervisor in
            // The shared helper agrees across surfaces: shell and desktop
            // compute the same undeclared set for identical inputs.
            let screened = ["api.example.com"]
            #expect(supervisor.checkHosts(screened, against: ["api.example.com"]).isEmpty)
            #expect(SeatbeltProfileBuilder.sanitizedEgressHosts(["API.Example.COM"]) == ["api.example.com"])

            let bridge = DesktopControlBridge(
                accessibilityAccess: { true },
                egressSupervisor: supervisor
            )
            let actions = [DesktopAction.typeText(text: "open https://api.example.com/data now")]
            do {
                _ = try await bridge.executeBatch(
                    actions: actions,
                    scaleX: 1.0,
                    scaleY: 1.0,
                    blockedApps: [],
                    sessionID: UUID(),
                    declaredHosts: ["api.example.com"]
                )
                // macOS dispatches here; other platforms prove screening
                // passed by reaching the platform gate instead of blockedURL.
            } catch let error as DesktopControlError {
                switch error {
                case .blockedURL:
                    Issue.record("Declared host must not deny as blockedURL")
                default:
                    break
                }
            }
        }
    }
}

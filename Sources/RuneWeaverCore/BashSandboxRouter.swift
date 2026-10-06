// Rune Weaver Core — Tier routing plus scoped mounts for sandboxed shell execution.

import Foundation

/// Namespace owning tier resolution plus scoped mount and profile helpers.
public enum BashSandboxRouter: Sendable {
    /// Resolves the execution tier for one command.
    ///
    /// Chained commands never reach the host tier: any chaining operator,
    /// substitution, or subshell fails closed to the configured sandbox mode
    /// before allow patterns are consulted, so a wildcard match over the full
    /// command string cannot carry an attacker suffix into `hostSeatbelt`.
    /// Unchained commands keep the existing opt-out; ordering carries no
    /// meaning because the outcome stays binary. Matching reuses
    /// `BashSecurity.matches` so allow entries accept the same fnmatch
    /// wildcards and bare-prefix spellings owners already use for permission
    /// rules, keeping tier opt-out consistent with policy.
    public static func resolveTier(command: String, config: BashConfig) -> BashSandboxMode {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if BashSecurity.detectChaining(in: trimmed) {
            return config.sandboxMode
        }
        if config.hostAllowPatterns.contains(where: { BashSecurity.matches(command: trimmed, pattern: $0) }) {
            return .hostSeatbelt
        }
        return config.sandboxMode
    }

    /// Workspace `tmp/` URL for one root.
    public static func workspaceTmpURL(for workspaceRoot: URL) -> URL {
        workspaceRoot.appendingPathComponent(WorkspaceStore.tmpDirectoryName)
    }

    /// Host paths mounted for one tier.
    ///
    /// Single mount contract backing Seatbelt scoping: the strict tier scopes
    /// to workspace `tmp`, the machine tier scopes to the workspace root, and
    /// the host tier has no container mount (empty) because host runs on the
    /// Mac with Seatbelt scoped to the working directory instead.
    public static func mountedHostPaths(for tier: BashSandboxMode, workspaceRoot: URL) -> [String] {
        let root = workspaceRoot.standardizedFileURL.path
        let tmp = workspaceTmpURL(for: workspaceRoot).standardizedFileURL.path
        switch tier {
        case .strictContainer:
            return [tmp]
        case .machineScoped:
            return [root]
        case .hostSeatbelt:
            return []
        }
    }

    /// Seatbelt profile scoped to one tier.
    ///
    /// Isolated tiers derive their allowed roots from `mountedHostPaths` so
    /// routing, mounts, and Seatbelt confinement agree on one contract; the
    /// host tier has no container mount and scopes Seatbelt to the working
    /// directory instead.
    public static func seatbeltProfile(
        for tier: BashSandboxMode,
        workspaceRoot: URL,
        workingDir: URL?,
        allowNetwork: Bool,
        declaredHosts: [String] = []
    ) -> String {
        let tmp = workspaceTmpURL(for: workspaceRoot).standardizedFileURL.path
        switch tier {
        case .strictContainer, .machineScoped:
            let mounts = mountedHostPaths(for: tier, workspaceRoot: workspaceRoot)
            let builder = SeatbeltProfileBuilder(
                allowedReadPaths: SeatbeltProfileBuilder.defaultSystemReadPaths + mounts,
                allowedWritePaths: SeatbeltProfileBuilder.defaultSystemWritePaths + mounts,
                deniedPaths: SeatbeltProfileBuilder.defaultDeniedPaths,
                allowNetwork: allowNetwork,
                allowedEgressHosts: declaredHosts
            )
            return builder.buildProfile()
        case .hostSeatbelt:
            let dir = (workingDir ?? workspaceRoot).standardizedFileURL.path
            var reads = Set(SeatbeltProfileBuilder.defaultSystemReadPaths)
            reads.insert(dir)
            reads.insert(tmp)
            var writes = Set(SeatbeltProfileBuilder.defaultSystemWritePaths)
            writes.insert(dir)
            let builder = SeatbeltProfileBuilder(
                allowedReadPaths: Array(reads),
                allowedWritePaths: Array(writes),
                deniedPaths: SeatbeltProfileBuilder.defaultDeniedPaths,
                allowNetwork: allowNetwork,
                allowedEgressHosts: declaredHosts
            )
            return builder.buildProfile()
        }
    }

    /// Filtered environment for one tier with no HOME and no agent forwarding outside host.
    ///
    /// Isolated tiers allowlist a minimal key set without `HOME`; the host
    /// tier additionally keeps `HOME`. No tier forwards ssh-agent: the agent
    /// socket keys never survive filtering because `container run` only
    /// forwards when explicitly passed `--ssh`, which isolated and detonation
    /// paths never pass.
    public static func scopedEnvironment(for tier: BashSandboxMode, workingDir: URL) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let allowedKeys: [String] = switch tier {
        case .strictContainer, .machineScoped:
            ["PATH", "USER", "SHELL", "TMPDIR", "LANG", "LC_ALL", "TERM"]
        case .hostSeatbelt:
            ["PATH", "HOME", "USER", "SHELL", "TMPDIR", "LANG", "LC_ALL", "TERM"]
        }
        env = env.filter { allowedKeys.contains($0.key) }
        env.removeValue(forKey: "SSH_AUTH_SOCK")
        env.removeValue(forKey: "SSH_AGENT_PID")
        env["PWD"] = workingDir.path
        env["RUNEWEAVER_BASH"] = "1"
        return env
    }

    /// Whether a schemeless host is embedded in a file path within one command.
    ///
    /// Staged agent copies (`/tmp/.../runeweaver-tool-UUID.sh`) plus other
    /// workspace file paths surface as dotted names whose trailing file
    /// extension reads as a TLD (`.sh`); a real dial (`curl example.com`)
    /// follows whitespace, never a path separator, so path-embedded matches
    /// stay local file artifacts, not egress dials. Callers skip these before
    /// screening so local runs stay host-free while true dials still screen.
    /// Every occurrence must sit behind a path separator to count as
    /// embedded: a command mixing a real dial with a later path echo
    /// (`curl evil.com; echo /evil.com`) still screens because the dial
    /// occurrence is not path-embedded.
    /// - Parameters:
    ///   - host: Bare host candidate from schemeless extraction.
    ///   - command: Raw shell command carrying the candidate.
    /// - Returns: True when every occurrence sits behind a path separator.
    public static func isPathEmbeddedHost(_ host: String, in command: String) -> Bool {
        guard !host.isEmpty, !command.isEmpty else { return false }
        let lowerCommand = command.lowercased()
        let lowerHost = host.lowercased()
        var searchFrom = lowerCommand.startIndex
        var foundAny = false
        while let range = lowerCommand.range(of: lowerHost, range: searchFrom ..< lowerCommand.endIndex) {
            foundAny = true
            if range.lowerBound == lowerCommand.startIndex {
                return false
            }
            let preceding = lowerCommand[lowerCommand.index(before: range.lowerBound)]
            if preceding != "/" {
                return false
            }
            searchFrom = range.upperBound
            if searchFrom >= lowerCommand.endIndex {
                break
            }
        }
        return foundAny
    }

    /// Whether one run needs egress screening for its tier.
    ///
    /// Isolated tiers screen every network-capable command even without an
    /// explicit network request, so a missing supervisor denies fail-closed
    /// instead of running unscreened; the host tier screens only when network
    /// egress is explicitly allowed. Screening itself stays declared-hosts
    /// first with the supervisor as the second opinion, so undeclared dials
    /// deny even when policy would allow them. Centralized here so the tool
    /// plus future callers agree on the tier gate without duplicating the branch.
    /// - Parameters:
    ///   - effectiveAllowNetwork: Whether this turn allows Seatbelt network.
    ///   - tier: Resolved sandbox tier for the command.
    ///   - isNetworkCapable: Whether the command names a network tool or host.
    /// - Returns: True when explicit-URL screening must run.
    public static func shouldScreenNetwork(
        effectiveAllowNetwork: Bool,
        tier: BashSandboxMode,
        isNetworkCapable: Bool
    ) -> Bool {
        effectiveAllowNetwork || (tier != .hostSeatbelt && isNetworkCapable)
    }
}

// Rune Weaver Core — Tier routing plus scoped mounts for sandboxed shell execution.

import Foundation

/// Namespace owning tier resolution plus scoped mount and profile helpers.
public enum BashSandboxRouter: Sendable {
    /// Toolchain resolution reads for `xcode-select` under the host tier.
    ///
    /// Every root carries both spellings — symlinked (`/var/...`) and
    /// canonical (`/private/var/...`): the kernel evaluates opens on the
    /// canonical path while callers spell the symlinked one, so a
    /// single-spelling entry can deny a read the profile intends to allow.
    /// Future path additions must carry both spellings of the same root.
    static let hostToolchainReadPaths = [
        "/var/select",
        "/private/var/select",
        "/var/db/xcode_select_link",
        "/private/var/db/xcode_select_link"
    ]

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

    /// Effective execution tier shared by approval stamping and the bash tool.
    ///
    /// Applies the host fallback the executor enforces for staged copies,
    /// hermetic scratch roots, and system-temp paths so the stamped summary
    /// cannot advertise an isolated tier while execution runs on the host.
    public static func effectiveTier(
        command: String,
        config: BashConfig,
        rawCwd: String? = nil,
        workspaceRoot: URL? = nil
    ) -> BashSandboxMode {
        let base = resolveTier(command: command, config: config)
        return applyHostFallback(baseTier: base, command: command, rawCwd: rawCwd, workspaceRoot: workspaceRoot)
    }

    /// Applies the executor host fallback to a resolved base tier.
    ///
    /// Single fallback owner so stamping and execution cannot drift: staged
    /// copies and hermetic roots force host unconditionally, while temp paths
    /// force host only when the base tier is isolated. Staged-copy and temp
    /// matches run on expanded path tokens, never raw substrings, so an echo
    /// of a name stays isolated while an executed staged path still maps host.
    public static func applyHostFallback(
        baseTier: BashSandboxMode,
        command: String,
        rawCwd: String? = nil,
        workspaceRoot: URL? = nil
    ) -> BashSandboxMode {
        if commandReferencesStagedCopyPath(command) {
            return .hostSeatbelt
        }
        if let root = workspaceRoot, isHermeticWorkspaceRoot(root) {
            return .hostSeatbelt
        }
        if baseTier != .hostSeatbelt, requiresHostForSystemTemp(command: command, rawCwd: rawCwd, workspaceRoot: workspaceRoot) {
            return .hostSeatbelt
        }
        return baseTier
    }

    /// Whether the executed argv references a staged agent-tool copy.
    ///
    /// Matches the staged filename only as a path token carrying a separator,
    /// so `echo runeweaver-tool-x` stays isolated while the quoted staged
    /// execution `'.../runeweaver-tool-UUID.sh'` still maps host. The first
    /// shell word owns the verdict because it is the executed path; later
    /// words are data for that execution, not a second execution needing host.
    static func commandReferencesStagedCopyPath(_ command: String) -> Bool {
        guard let first = firstShellWord(command) else { return false }
        return first.contains("runeweaver-tool-") && first.contains("/")
    }

    /// First shell word with surrounding quotes stripped.
    ///
    /// Skips leading whitespace; a leading single or double quote parses to its
    /// mate so the quoted staged path counts as one word. Unbalanced quotes
    /// fall back to the whitespace-delimited token.
    static func firstShellWord(_ command: String) -> String? {
        var index = command.startIndex
        while index < command.endIndex, command[index].isWhitespace {
            index = command.index(after: index)
        }
        guard index < command.endIndex else { return nil }
        let quote: Character? = (command[index] == "'" || command[index] == "\"") ? command[index] : nil
        if let quote {
            let afterOpen = command.index(after: index)
            if let close = command[afterOpen...].firstIndex(of: quote) {
                let inner = String(command[afterOpen ..< close])
                return inner.isEmpty ? nil : inner
            }
        }
        var end = index
        while end < command.endIndex,
              !command[end].isWhitespace,
              command[end] != ";",
              command[end] != "|",
              command[end] != "&",
              command[end] != "(",
              command[end] != ")",
              command[end] != "<",
              command[end] != ">"
        {
            end = command.index(after: end)
        }
        let token = String(command[index ..< end]).trimmingCharacters(in: .whitespacesAndNewlines)
        let stripped = token.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        return stripped.isEmpty ? nil : stripped
    }

    /// Unquoted shell words for temp-path fallback.
    ///
    /// Tracks single plus double quote state so a quoted `"/tmp/foo"` echo
    /// stays data while an unquoted `/tmp/foo` path still maps host. Words
    /// split on whitespace plus shell operators outside quotes; quoted words
    /// are excluded because they are string data, not executed paths.
    static func unquotedShellWords(_ command: String) -> [String] {
        var words: [String] = []
        var current = ""
        var hasCurrent = false
        var quote: Character?
        var currentWasQuoted = false
        func flush() {
            if hasCurrent, !currentWasQuoted, !current.isEmpty {
                words.append(current)
            }
            current = ""
            hasCurrent = false
            currentWasQuoted = false
        }
        var index = command.startIndex
        while index < command.endIndex {
            let character = command[index]
            if let open = quote {
                if character == open {
                    quote = nil
                } else {
                    current += String(character)
                    hasCurrent = true
                }
            } else if character == "'" || character == "\"" {
                quote = character
                currentWasQuoted = true
                hasCurrent = true
            } else if character.isWhitespace || character == ";" || character == "|"
                || character == "&" || character == "(" || character == ")"
                || character == "<" || character == ">"
            {
                flush()
            } else {
                current += String(character)
                hasCurrent = true
            }
            index = command.index(after: index)
        }
        flush()
        return words
    }

    /// Whether an unquoted path token sits under system temp.
    ///
    /// Matches temp as a prefix on unquoted path tokens, never as a raw
    /// substring, so `echo "/tmp/foo"` stays isolated while `cat /tmp/foo`
    /// still maps host for the executed path.
    static func commandReferencesSystemTempPath(_ command: String) -> Bool {
        for word in unquotedShellWords(command) {
            let expanded = (word as NSString).expandingTildeInPath
            guard expanded.hasPrefix("/") else { continue }
            if isSystemTempPath(expanded) {
                return true
            }
        }
        return false
    }

    /// Whether a workspace root is hermetic scratch under system temp.
    static func isHermeticWorkspaceRoot(_ root: URL) -> Bool {
        let tmp = FileManager.default.temporaryDirectory.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        let prefix = tmp.hasSuffix("/") ? tmp : tmp + "/"
        return rootPath == tmp || rootPath.hasPrefix(prefix)
    }

    /// Whether an isolated tier cannot honor this turn without hiding host temp.
    ///
    /// Cwd inside system temp forces host because no isolated mount covers it;
    /// command temp references force host only as unquoted path-token prefixes,
    /// never raw substrings, so an echo of a temp name stays isolated.
    static func requiresHostForSystemTemp(command: String, rawCwd: String?, workspaceRoot: URL?) -> Bool {
        if let workspaceRoot {
            let trimmedCwd = (rawCwd ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedCwd.isEmpty {
                let expanded = (trimmedCwd as NSString).expandingTildeInPath
                let candidate: URL =
                    if expanded.hasPrefix("/") {
                        URL(fileURLWithPath: expanded).standardizedFileURL
                    } else {
                        workspaceRoot.appendingPathComponent(expanded).standardizedFileURL
                    }
                if isOutsideWorkspace(path: candidate, workspaceRoot: workspaceRoot),
                   isSystemTempPath(candidate.path)
                {
                    return true
                }
            }
        } else if let rawCwd {
            let trimmed = rawCwd.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let expanded = (trimmed as NSString).expandingTildeInPath
                if expanded.hasPrefix("/"), isSystemTempPath(expanded) {
                    return true
                }
            }
        }
        if commandReferencesSystemTempPath(command) {
            return true
        }
        return false
    }

    /// Symlink-resolved outside-workspace check.
    static func isOutsideWorkspace(path: URL, workspaceRoot: URL) -> Bool {
        let root = workspaceRoot.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        let candidate = path.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        if candidate.path == root.path {
            return false
        }
        return !candidate.path.hasPrefix(root.path + "/")
    }

    /// Whether a path sits under system temp.
    static func isSystemTempPath(_ path: String) -> Bool {
        let prefixes = ["/private/tmp/", "/tmp/", "/private/var/folders/", "/var/folders/"]
        for prefix in prefixes where path == String(prefix.dropLast()) || path.hasPrefix(prefix) {
            return true
        }
        let tmp = FileManager.default.temporaryDirectory.standardizedFileURL.path
        if !tmp.isEmpty, path == tmp || path.hasPrefix(tmp.hasSuffix("/") ? tmp : tmp + "/") {
            return true
        }
        return false
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
            reads.formUnion(Self.hostToolchainReadPaths)
            var writes = Set(SeatbeltProfileBuilder.defaultSystemWritePaths)
            writes.insert(dir)
            let builder = SeatbeltProfileBuilder(
                allowedReadPaths: Array(reads),
                allowedWritePaths: Array(writes),
                deniedPaths: SeatbeltProfileBuilder.defaultDeniedPaths,
                allowNetwork: allowNetwork,
                allowedEgressHosts: declaredHosts
            )
            let profile = builder.buildProfile()
            // DVTKeychain frameworks match the lowercase filename deny despite the capital K, so drop that single
            // regex on host; real stores stay denied via the Keychains subpath deny. Exact line equality keeps
            // the exemption to that one deny so a rename or addition fails visibly instead of widening silently,
            // and no subpath allow line can match.
            let keychainFilenameDenyLine = ##"    (regex #"/[^/]*keychain[^/]*"#)"##
            return profile
                .components(separatedBy: "\n")
                .filter { $0 != keychainFilenameDenyLine }
                .joined(separator: "\n")
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
            ["PATH", "HOME", "USER", "SHELL", "TMPDIR", "LANG", "LC_ALL", "TERM", "DEVELOPER_DIR"]
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

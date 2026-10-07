// Rune Weaver CLI — Agent scratch workspace plus hash-pinned script registry.
//
// Exposes the bounded `workspace/` scratch tree and the `agent-tools`
// promotion registry direct-core, without the engine service: usage with
// quotas, age-based `tmp/` pruning with honest reclaimed bytes, listing with
// pins, promotion confined to `workspace/tools/`, verified execution, and
// explicit disablement. The command layer is a thin display over the shared
// WorkspaceStore and AgentToolStore, so every mutation observes the same
// registry the service advances and no session is ever linked.

import ArgumentParser
import Foundation
import RuneWeaverCore
import RuneWeaverTools

/// Manages the agent scratch workspace: usage, prune, and promoted tools.
struct WorkspaceCommand: AsyncParsableCommand {
    /// Top-level command configuration.
    static let configuration = CommandConfiguration(
        commandName: "workspace",
        abstract: "Inspect and prune the agent workspace and manage promoted tools.",
        subcommands: [
            WorkspaceUsageCommand.self,
            WorkspacePruneCommand.self,
            WorkspaceMachineCommand.self,
            WorkspaceToolsCommand.self
        ],
        defaultSubcommand: WorkspaceUsageCommand.self
    )
}

/// Reports bounded scratch usage with quotas.
struct WorkspaceUsageCommand: AsyncParsableCommand {
    /// Top-level command configuration.
    static let configuration = CommandConfiguration(
        commandName: "usage",
        abstract: "Show workspace disk and file usage against quotas."
    )

    /// Config file path override.
    @Option(name: .long, help: "Path to config.toml (defaults to ~/.runeweaver/config.toml).")
    var config: String?

    /// Prints the bounded walk counts plus the configured quotas.
    mutating func run() async throws {
        let loaded = try CLIConfigLoader.loadConfig(path: config)
        if loaded.isFallback {
            print(TerminalStyle.dim("No config found at \(loaded.url.path); using built-in defaults."))
        }
        let store = WorkspaceStore(config: loaded.config.workspace)
        let usage = try await store.usage()
        let limits = await store.config.clamped()
        let quotaBytes = limits.quotaMB * 1024 * 1024
        let bytesPercent = quotaBytes > 0 ? Int((Double(usage.bytes) / Double(quotaBytes)) * 100) : 0
        let filesPercent = limits.quotaFiles > 0 ? Int((Double(usage.files) / Double(limits.quotaFiles)) * 100) : 0
        await print("Workspace: \(storeRootDescription(store))")
        print("  bytes: \(usage.bytes) / \(quotaBytes) (\(min(max(bytesPercent, 0), 100))%)")
        print("  files: \(usage.files) / \(limits.quotaFiles) (\(min(max(filesPercent, 0), 100))%)")
        if usage.truncated {
            print(TerminalStyle.dim("  note: walk truncated; actual usage may be higher."))
        }
        // A truncated walk fails closed in `checkQuota` even when its lower
        // bounds sit under quota, because the unseen remainder may exceed it;
        // the display mirrors that gate so `usage` never reads clean while
        // the next shell turn would refuse.
        if usage.truncated || usage.bytes > quotaBytes || usage.files > limits.quotaFiles {
            print(TerminalStyle.error("Quota exceeded: prune workspace/tmp or raise [workspace] quotas."))
        }
    }

    /// Best-effort root description without touching disk beyond the store.
    private func storeRootDescription(_ store: WorkspaceStore) async -> String {
        await store.root().path
    }
}

/// Clears expired `tmp/` entries, reporting the honest reclaimed bytes.
struct WorkspacePruneCommand: AsyncParsableCommand {
    /// Top-level command configuration.
    static let configuration = CommandConfiguration(
        commandName: "prune",
        abstract: "Prune expired workspace/tmp entries."
    )

    /// Config file path override.
    @Option(name: .long, help: "Path to config.toml (defaults to ~/.runeweaver/config.toml).")
    var config: String?

    /// Prunes by age and prints the removed count plus reclaimed bytes.
    mutating func run() async throws {
        let loaded = try CLIConfigLoader.loadConfig(path: config)
        if loaded.isFallback {
            print(TerminalStyle.dim("No config found at \(loaded.url.path); using built-in defaults."))
        }
        let store = WorkspaceStore(config: loaded.config.workspace)
        let before = try await store.usage().bytes
        let removed: Int
        do {
            removed = try await store.pruneTmp()
        } catch {
            print(TerminalStyle.error("Workspace prune failed: \(error.localizedDescription)"))
            throw ExitCode(1)
        }
        let after = try await store.usage().bytes
        let reclaimed = max(0, before - after)
        if removed == 0 {
            print(TerminalStyle.dim("Nothing to prune (0 entries removed, 0 bytes reclaimed)."))
        } else {
            print(TerminalStyle.success("Pruned \(removed) tmp entr\(removed == 1 ? "y" : "ies"), reclaimed \(reclaimed) bytes (\(before) -> \(after))."))
        }
    }
}

/// Manages the workspace machine container: status, stop, and recycle.
struct WorkspaceMachineCommand: AsyncParsableCommand {
    /// Top-level command configuration.
    static let configuration = CommandConfiguration(
        commandName: "machine",
        abstract: "Inspect and control the workspace machine container.",
        subcommands: [
            WorkspaceMachineStatusCommand.self,
            WorkspaceMachineStopCommand.self,
            WorkspaceMachineRecycleCommand.self
        ],
        defaultSubcommand: WorkspaceMachineStatusCommand.self
    )
}

/// Reports machine lifecycle state.
struct WorkspaceMachineStatusCommand: AsyncParsableCommand {
    /// Top-level command configuration.
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show workspace machine status."
    )

    /// Config file path override.
    @Option(name: .long, help: "Path to config.toml (defaults to ~/.runeweaver/config.toml).")
    var config: String?

    /// Prints live exists plus running plus image plus config agreement.
    mutating func run() async throws {
        let loaded = try CLIConfigLoader.loadConfig(path: config)
        if loaded.isFallback {
            print(TerminalStyle.dim("No config found at \(loaded.url.path); using built-in defaults."))
        }
        let store = WorkspaceStore(config: loaded.config.workspace)
        let root = await store.root()
        let networkDenied = !loaded.config.bash.allowNetwork
        let status = await MachineScopedRunner.machineStatus(workspaceRoot: root, networkDenied: networkDenied)
        await print("Machine: \(storeRootDescription(store))")
        print("  exists: \(status.exists)")
        print("  running: \(status.running)")
        print("  image: \(status.image.isEmpty ? "(unknown)" : status.image)")
        print("  configMatch: \(status.configMatch.map(String.init(describing:)) ?? "(unknown)")")
        if !status.exists {
            print(TerminalStyle.dim("  note: no machine container; the next run recreates it."))
        }
    }

    /// Best-effort root description without touching disk beyond the store.
    private func storeRootDescription(_ store: WorkspaceStore) async -> String {
        await store.root().path
    }
}

/// Stops the machine container without removing it.
struct WorkspaceMachineStopCommand: AsyncParsableCommand {
    /// Top-level command configuration.
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "Stop the workspace machine without removing it."
    )

    /// Config file path override.
    @Option(name: .long, help: "Path to config.toml (defaults to ~/.runeweaver/config.toml).")
    var config: String?

    /// Halts the machine then prints the live post-stop state.
    mutating func run() async throws {
        let loaded = try CLIConfigLoader.loadConfig(path: config)
        if loaded.isFallback {
            print(TerminalStyle.dim("No config found at \(loaded.url.path); using built-in defaults."))
        }
        let store = WorkspaceStore(config: loaded.config.workspace)
        await MachineScopedRunner.stopMachine()
        let root = await store.root()
        let networkDenied = !loaded.config.bash.allowNetwork
        let status = await MachineScopedRunner.machineStatus(workspaceRoot: root, networkDenied: networkDenied)
        if !status.exists {
            print(TerminalStyle.dim("No machine container (nothing to stop)."))
        } else {
            print(TerminalStyle.success("Stopped workspace machine (running: \(status.running))."))
        }
    }
}

/// Stops plus removes the machine container so the next run recreates it.
struct WorkspaceMachineRecycleCommand: AsyncParsableCommand {
    /// Top-level command configuration.
    static let configuration = CommandConfiguration(
        commandName: "recycle",
        abstract: "Stop and remove the workspace machine so the next run recreates it."
    )

    /// Config file path override.
    @Option(name: .long, help: "Path to config.toml (defaults to ~/.runeweaver/config.toml).")
    var config: String?

    /// Removes the machine then prints the live post-recycle state.
    mutating func run() async throws {
        let loaded = try CLIConfigLoader.loadConfig(path: config)
        if loaded.isFallback {
            print(TerminalStyle.dim("No config found at \(loaded.url.path); using built-in defaults."))
        }
        let store = WorkspaceStore(config: loaded.config.workspace)
        await MachineScopedRunner.recycleMachine()
        let root = await store.root()
        let networkDenied = !loaded.config.bash.allowNetwork
        let status = await MachineScopedRunner.machineStatus(workspaceRoot: root, networkDenied: networkDenied)
        if status.exists {
            print(TerminalStyle.error("Recycle did not remove the machine (exists: true, running: \(status.running))."))
        } else {
            print(TerminalStyle.success("Recycled workspace machine (next run recreates it)."))
        }
    }
}

/// Manages promoted agent scripts: list, promote, run, and disable.
struct WorkspaceToolsCommand: AsyncParsableCommand {
    /// Top-level command configuration.
    static let configuration = CommandConfiguration(
        commandName: "tools",
        abstract: "Manage promoted agent tools: list, promote, run, disable.",
        subcommands: [
            WorkspaceToolsListCommand.self,
            WorkspaceToolsPromoteCommand.self,
            WorkspaceToolsRunCommand.self,
            WorkspaceToolsDisableCommand.self
        ],
        defaultSubcommand: WorkspaceToolsListCommand.self
    )
}

/// Shared direct-core wiring for the tools subcommands.
enum WorkspaceToolsShared {
    /// Builds the workspace plus pin stores from the resolved config.
    static func makeStores(loaded: CLIConfigLoader.LoadedConfig) -> (WorkspaceStore, AgentToolStore) {
        let workspace = WorkspaceStore(config: loaded.config.workspace)
        let episodesDB = loaded.config.memory.episodesDBPath
        let tools = AgentToolStore(dbPath: episodesDB, workspaceStore: workspace)
        return (workspace, tools)
    }

    /// Resolves one tool by name or identifier, failing honestly on unknown rows.
    ///
    /// A store failure surfaces its own message rather than masquerading as an
    /// unknown row, so a broken database never reads as "not promoted".
    static func resolveTool(store: AgentToolStore, raw: String) async throws -> AgentToolRecord {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if let id = UUID(uuidString: trimmed) {
                if let byID = try await store.get(id: id) {
                    return byID
                }
            }
            if let byName = try await store.get(name: trimmed) {
                return byName
            }
        } catch {
            print(TerminalStyle.error(error.localizedDescription))
            throw ExitCode(1)
        }
        print(TerminalStyle.error("Unknown agent tool '\(raw)'."))
        throw ExitCode(1)
    }

    /// Short hash prefix for dense terminal rows.
    static func shortHash(_ sha256: String) -> String {
        String(sha256.lowercased().prefix(12))
    }
}

/// Lists every pinned script ordered by name.
struct WorkspaceToolsListCommand: AsyncParsableCommand {
    /// Top-level command configuration.
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List promoted agent tools."
    )

    /// Config file path override.
    @Option(name: .long, help: "Path to config.toml (defaults to ~/.runeweaver/config.toml).")
    var config: String?

    /// Prints one row per pinned script with its pin prefix and status.
    mutating func run() async throws {
        let loaded = try CLIConfigLoader.loadConfig(path: config)
        let (workspace, tools) = WorkspaceToolsShared.makeStores(loaded: loaded)
        // Fresh boots may lack the scratch root: ensure it plus prune stale
        // tmp/ before touching the stores, mirroring the pluginTools ensure.
        await CLIShared.ensureWorkspace(config: loaded.config.workspace, store: workspace)
        let records: [AgentToolRecord]
        do {
            records = try await tools.list()
        } catch {
            print(TerminalStyle.error(error.localizedDescription))
            throw ExitCode(1)
        }
        guard !records.isEmpty else {
            print(TerminalStyle.dim("No agent tools promoted. Promote one with 'rune-weaver workspace tools promote <name> --script tools/<file>'."))
            return
        }
        print("Agent tools (\(records.count)):")
        for record in records {
            let marker = record.status == .enabled ? TerminalStyle.success("●") : TerminalStyle.dim("○")
            print("  \(marker) \(record.name) [\(record.status.rawValue)] \(WorkspaceToolsShared.shortHash(record.sha256)) \(record.scriptPath)")
        }
    }
}

/// Promotes a `tools/` script, pinning its exact bytes.
struct WorkspaceToolsPromoteCommand: AsyncParsableCommand {
    /// Top-level command configuration.
    static let configuration = CommandConfiguration(
        commandName: "promote",
        abstract: "Promote a tools/ script under a short name."
    )

    /// Registry name for later runs.
    @Argument(help: "Registry name (letters, numbers, '-', '_', '.').")
    var name: String

    /// Script path inside tools/.
    @Option(name: .long, help: "Script path inside tools/ to pin.")
    var script: String

    /// Config file path override.
    @Option(name: .long, help: "Path to config.toml (defaults to ~/.runeweaver/config.toml).")
    var config: String?

    /// Pins the script bytes and prints the resulting row.
    mutating func run() async throws {
        let loaded = try CLIConfigLoader.loadConfig(path: config)
        let (workspace, tools) = WorkspaceToolsShared.makeStores(loaded: loaded)
        // Promotion stages through the scratch tree, so ensure the root plus
        // prune stale tmp/ before pinning, mirroring the pluginTools ensure.
        await CLIShared.ensureWorkspace(config: loaded.config.workspace, store: workspace)
        do {
            let record = try await tools.promote(name: name, scriptPath: script)
            print(TerminalStyle.success("Promoted '\(record.name)' (\(WorkspaceToolsShared.shortHash(record.sha256))) [\(record.status.rawValue)]"))
            print(TerminalStyle.dim("  \(record.scriptPath)"))
        } catch let error as AgentToolStoreError {
            print(TerminalStyle.error(error.localizedDescription))
            throw ExitCode(1)
        }
    }
}

/// Encodable `tool.run` input for the direct-core run path.
///
/// Encoding rides `JSONEncoder` so the CLI never rebuilds shell text: the
/// staged shell command stays single-sourced inside `RunAgentTool` via
/// `AgentToolStaging.bashInput`, and this payload carries only the registry
/// name plus literal argv the runner verifies and stages.
private struct WorkspaceToolRunPayload: Encodable {
    /// Registry name pinned at promotion time.
    let name: String
    /// Caller arguments appended after `--` as literal argv, omitted when empty.
    let argv: [String]?

    private enum CodingKeys: String, CodingKey {
        case name
        case argv
    }

    /// Encodes one run payload, omitting an empty argv like the model path.
    static func encode(name: String, argv: [String]) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = WorkspaceToolRunPayload(name: trimmed, argv: argv.isEmpty ? nil : argv)
        let data = try JSONEncoder().encode(payload)
        return String(data: data, encoding: .utf8) ?? #"{"name":""}"#
    }

    /// Encodes the name plus an omitted-when-empty argv.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(argv, forKey: .argv)
    }
}

/// Runs one pinned script after re-verifying its hash.
struct WorkspaceToolsRunCommand: AsyncParsableCommand {
    /// Top-level command configuration.
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run a promoted agent tool by name."
    )

    /// Registry name pinned at promotion time.
    @Argument(help: "Registry name pinned at promotion time.")
    var name: String

    /// Extra argv appended after `--` as literal words.
    @Argument(parsing: .captureForPassthrough, help: "Arguments appended after -- as literal argv.")
    var argv: [String] = []

    /// Config file path override.
    @Option(name: .long, help: "Path to config.toml (defaults to ~/.runeweaver/config.toml).")
    var config: String?

    /// Verifies the pin then dispatches through the shared shell with literal argv.
    mutating func run() async throws {
        let loaded = try CLIConfigLoader.loadConfig(path: config)
        let (workspace, tools) = WorkspaceToolsShared.makeStores(loaded: loaded)
        // The run path shells out, so ensure the scratch root plus prune stale
        // tmp/ before verifying or spawning, mirroring the pluginTools ensure.
        await CLIShared.ensureWorkspace(config: loaded.config.workspace, store: workspace)
        var cleanedArgv = argv
        if cleanedArgv.first == "--" {
            cleanedArgv.removeFirst()
        }
        guard cleanedArgv.count <= RunAgentTool.maxArgvCount else {
            print(TerminalStyle.error("Too many arguments (got \(cleanedArgv.count), max \(RunAgentTool.maxArgvCount))."))
            throw ExitCode(1)
        }
        // Direct-core runs thread the same verified egress supervisor as the
        // service and chat paths: a supervisor-less `BashTool` would screen
        // nothing, turning `bash.allow_network=true` into blanket-allow
        // without `validate()`/policy/SSRF. Boot fails closed when no
        // verified policy exists.
        let policyStore = await PolicyStore.makeLoaded(injected: nil)
        let supervisor: OutboundEgressSupervisor
        do {
            supervisor = try await OutboundEgressSupervisor.make(
                policyStore: policyStore,
                browserConfig: loaded.config.browser,
                mediaConfig: loaded.config.media,
                llmServerURLs: CLIShared.llmServerURLs(from: loaded.config.llm)
            )
        } catch {
            print(TerminalStyle.error("Security policy rejected: \(error.localizedDescription)"))
            throw ExitCode(1)
        }
        let bash = BashTool(
            bashConfig: loaded.config.bash,
            filesConfig: loaded.config.files,
            egressSupervisor: supervisor,
            workspaceConfig: loaded.config.workspace,
            workspaceStore: workspace
        )
        // Single-flight lock for this process, held across verify plus spawn
        // inside `RunAgentTool`: the CLI passes its lock in rather than
        // building a parallel locker, mirroring the service run route. No
        // pre-`verify` runs here: `RunAgentTool.execute` owns the single
        // `verifyAndStage` (one hash, one disable path, one status check),
        // so a prior `verify` would double-hash and double-disable.
        let runLock = AgentToolRunLock()
        let runner = RunAgentTool(store: tools, bash: bash, workspace: workspace, runLock: runLock)
        // The staged shell stays single-sourced via `AgentToolStaging.bashInput`
        // inside the runner; this payload carries only the registry name plus
        // literal argv encoded with `JSONEncoder`, never rebuilt shell text.
        let argumentsJSON: String
        do {
            argumentsJSON = try WorkspaceToolRunPayload.encode(name: name, argv: cleanedArgv)
        } catch {
            print(TerminalStyle.error("Agent tool '\(name)' failed: could not encode arguments."))
            throw ExitCode(1)
        }
        // Direct-core runs are owner-invoked, so they execute approved rather
        // than parking in the approvals inbox like a model turn would. No
        // session is linked: the CLI never owns the dashboard session story.
        let context = ToolContext(conversationID: UUID(), approved: true)
        let output: ToolOutput
        do {
            output = try await runner.execute(
                input: ToolInput(toolName: runner.name, argumentsJSON: argumentsJSON, callID: UUID().uuidString),
                context: context
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            print(TerminalStyle.error("Agent tool '\(name)' failed: \(error.localizedDescription)"))
            throw ExitCode(1)
        }
        print(output.content)
        if output.isError {
            throw ExitCode(1)
        }
    }
}

/// Disables one pinned script by name or identifier.
struct WorkspaceToolsDisableCommand: AsyncParsableCommand {
    /// Top-level command configuration.
    static let configuration = CommandConfiguration(
        commandName: "disable",
        abstract: "Disable a promoted agent tool."
    )

    /// Registry name or identifier.
    @Argument(help: "Registry name or identifier to disable.")
    var target: String

    /// Config file path override.
    @Option(name: .long, help: "Path to config.toml (defaults to ~/.runeweaver/config.toml).")
    var config: String?

    /// Moves the row to disabled, failing honestly on unknown rows.
    mutating func run() async throws {
        let loaded = try CLIConfigLoader.loadConfig(path: config)
        let (workspace, tools) = WorkspaceToolsShared.makeStores(loaded: loaded)
        // Disablement rewrites registry rows beside the scratch tree, so
        // ensure the root plus prune stale tmp/ first like the sibling tools.
        await CLIShared.ensureWorkspace(config: loaded.config.workspace, store: workspace)
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if let id = UUID(uuidString: trimmed) {
                _ = try await tools.setStatus(id: id, status: .disabled)
            } else {
                _ = try await tools.setStatus(name: trimmed, status: .disabled)
            }
            print(TerminalStyle.success("Disabled agent tool '\(trimmed)'."))
        } catch let error as AgentToolStoreError {
            print(TerminalStyle.error(error.localizedDescription))
            throw ExitCode(1)
        }
    }
}

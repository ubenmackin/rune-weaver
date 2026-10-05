// Rune Weaver Tools — Owner-promoted script tools for the shared ToolBus (`tool.promote`, `tool.run`).
//
// Purpose: exposes the hash-pinned `workspace/tools/` registry to the model as
// two approval-gated tools: promotion that pins exact file bytes under a short
// name, and verified execution that re-hashes before every dispatch so a
// modified script fails closed instead of running silently changed bytes.
// Scope: argument decoding, pin verification, and shell dispatch only;
// durability and hashing live in AgentToolStore, sandboxing and quotas live in
// BashTool and WorkspaceStore. Architectural role: the agent's lever for
// owner-blessed automation — promotion teaches that only `workspace/tools/`
// is eligible, execution appends caller arguments after `--` as literal argv
// so injection attempts never touch the pinned script text, and graduated
// trust treats repeats exactly like `bash.exec` repeats.

import Foundation
import RuneWeaverCore

// MARK: - Arguments

/// Arguments for `tool.promote`.
public struct PromoteAgentToolArgs: Sendable, Equatable, Decodable {
    /// Registry name for later runs.
    public let name: String
    /// Script path to pin (absolute, tilde, or workspace-relative).
    public let scriptPath: String

    /// Creates promote args.
    public init(name: String, scriptPath: String) {
        self.name = name
        self.scriptPath = scriptPath
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case scriptPath
        case scriptPathSnake = "script_path"
        case path
    }

    /// Decodes promote args; `script_path` is the advertised wire key while
    /// `scriptPath` and `path` stay compatibility-only aliases kept out of the
    /// strict schema, so the wire stays fail-closed while older callers still decode.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        if let snake = try container.decodeIfPresent(String.self, forKey: .scriptPathSnake) {
            scriptPath = snake
        } else if let camel = try container.decodeIfPresent(String.self, forKey: .scriptPath) {
            scriptPath = camel
        } else if let short = try container.decodeIfPresent(String.self, forKey: .path) {
            scriptPath = short
        } else {
            scriptPath = ""
        }
    }

    /// Trimmed registry name.
    public var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Trimmed script path.
    public var trimmedScriptPath: String {
        scriptPath.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Arguments for `tool.run`.
public struct RunAgentToolArgs: Sendable, Equatable, Decodable {
    /// Registry name pinned at promotion time.
    public let name: String
    /// Caller arguments appended after `--` as literal argv.
    public let argv: [String]?

    /// Creates run args.
    public init(name: String, argv: [String]? = nil) {
        self.name = name
        self.argv = argv
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case argv
        case args
        case arguments
    }

    /// Decodes run args; `args` and `arguments` are compatibility-only aliases
    /// kept out of the strict schema, which advertises `argv` only, so the
    /// wire stays fail-closed while older callers still decode.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        if let direct = try container.decodeIfPresent([String].self, forKey: .argv) {
            argv = direct
        } else if let alias = try container.decodeIfPresent([String].self, forKey: .args) {
            argv = alias
        } else if let plural = try container.decodeIfPresent([String].self, forKey: .arguments) {
            argv = plural
        } else {
            argv = nil
        }
    }

    /// Trimmed registry name.
    public var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Effective argv, defaulting an omitted list to empty.
    public var effectiveArgv: [String] {
        argv ?? []
    }
}

// MARK: - Envelopes

/// Envelope wrapping `tool.promote` output.
public struct PromoteAgentToolEnvelope: Sendable, Equatable, Codable {
    /// Registry name that was pinned.
    public let name: String
    /// Absolute script path that was pinned.
    public let scriptPath: String
    /// Pinned SHA-256 hex of the file bytes.
    public let sha256: String
    /// Lifecycle state after promotion.
    public let status: String

    /// Creates a promote envelope.
    public init(name: String, scriptPath: String, sha256: String, status: String) {
        self.name = name
        self.scriptPath = scriptPath
        self.sha256 = sha256
        self.status = status
    }

    /// Builds an envelope from a stored row.
    public init(_ record: AgentToolRecord) {
        self.init(name: record.name, scriptPath: record.scriptPath, sha256: record.sha256, status: record.status.rawValue)
    }
}

/// Pure JSON encoding for the agent-tool output documents.
public enum AgentToolEncoding {
    /// Encodes any agent-tool envelope as the tool output document.
    public static func encode(_ envelope: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(envelope)
        return String(bytes: data, encoding: .utf8) ?? ""
    }
}

// MARK: - Shell quoting

/// Quotes one shell word so it always parses as a single literal.
///
/// Wraps in single quotes with embedded quotes escaped as `'"'"'`, so a
/// caller argument like `"; rm -rf /"` survives as one argv entry instead of
/// splitting into a second command. The pinned script path and every caller
/// argument ride this quoting, which is what keeps argv from ever touching
/// the script text. Single-sourced for the tools layer and the service run
/// route so both agree byte-for-byte.
public func shellQuoted(_ raw: String) -> String {
    "'" + raw.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
}

/// Single staging point for verified agent-tool shell dispatch.
///
/// The model path (`tool.run`) and the service run route execute the same
/// immutable workspace/tmp copy with the same literal argv handling, so the
/// command construction lives here rather than in each caller. The staged copy
/// (never the workspace original) rides the command so the bytes the shell
/// maps are exactly the bytes that matched the pin.
public enum AgentToolStaging {
    /// Builds the shell command for one staged copy plus literal argv.
    ///
    /// Every argv entry quotes as one literal word after `--`, so an entry
    /// like `"; rm -rf /"` arrives as data instead of splitting into a second
    /// command while the script text itself is never rebuilt.
    /// - Parameters:
    ///   - stagedURL: Staged copy carrying the verified bytes.
    ///   - argv: Caller arguments appended after `--` as literal argv.
    /// - Returns: Shell command executing the staged copy.
    public static func bashCommand(stagedURL: URL, argv: [String]) -> String {
        var command = shellQuoted(stagedURL.path)
        if !argv.isEmpty {
            command += " -- " + argv.map(shellQuoted).joined(separator: " ")
        }
        return command
    }

    /// Builds the encoded `bash.exec` input for one staged execution.
    ///
    /// The working directory pins to the eligible `tools/` directory so every
    /// script observes the same bounded cwd while the script path travels
    /// absolute, never resolved against a caller-controlled cwd.
    /// - Parameters:
    ///   - stagedURL: Staged copy carrying the verified bytes.
    ///   - argv: Caller arguments appended after `--` as literal argv.
    ///   - cwd: Pinned working directory for the shell.
    /// - Returns: Encoded `BashArgs` JSON for the shell tool.
    public static func bashInput(stagedURL: URL, argv: [String], cwd: String) throws -> String {
        let command = bashCommand(stagedURL: stagedURL, argv: argv)
        let args = BashArgs(command: command, cwd: cwd)
        let data = try JSONEncoder().encode(args)
        return String(bytes: data, encoding: .utf8) ?? #"{"command":""}"#
    }
}

// MARK: - Promote tool

/// `tool.promote` tool: pins a `workspace/tools/` script under a short name.
public struct PromoteAgentTool: Tool, Sendable {
    /// Stable tool name referenced by the LLM.
    public let name = "tool.promote"
    /// When the LLM should use this tool.
    public let description =
        "Promotes a script into the agent tool registry by pinning its exact bytes under a short name. "
            + "Use when the owner asks to bless an automation for later runs. "
            + "Only scripts inside workspace/tools/ are eligible; paths elsewhere are rejected. "
            + "Re-promotion updates the hash pin while keeping the disabled state until the owner re-enables it."
    /// Function-calling contract for the registry name and script path.
    public let inputSchema = JSONSchema(
        rawValue: #"{"type":"object","properties":{"#
            + #""name":{"type":"string","description":"Registry name for later runs (letters, numbers, '-', '_', '.')"},"#
            + #""script_path":{"type":"string","description":"Script path inside workspace/tools/ to pin"}},"#
            + #""required":["name","script_path"],"additionalProperties":false}"#
    )
    /// Promotion mutates the durable pin, so every call parks for approval.
    public let permissionLevel = PermissionLevel.requiresApproval

    /// Durable pin persistence.
    private let store: AgentToolStore

    /// Creates a promote tool.
    public init(store: AgentToolStore) {
        self.store = store
    }

    /// Pins the script bytes and returns the registry snapshot.
    public func execute(input: ToolInput, context: ToolContext) async throws -> ToolOutput {
        let args: PromoteAgentToolArgs
        do {
            args = try JSONDecoder().decode(PromoteAgentToolArgs.self, from: Data(input.argumentsJSON.utf8))
        } catch {
            return .failure(
                "Invalid tool.promote arguments:"
                    + " expected {\"name\": \"<slug>\", \"script_path\": \"<workspace/tools/...>\"}.",
                callID: input.callID
            )
        }
        guard !args.trimmedName.isEmpty, !args.trimmedScriptPath.isEmpty else {
            return .failure("Invalid tool.promote arguments: 'name' and 'script_path' must not be empty.", callID: input.callID)
        }
        if context.dryRun {
            return .success(
                "Dry run: would promote '\(args.trimmedScriptPath)'"
                    + " as '\(args.trimmedName)'. Only workspace/tools/ is eligible.",
                callID: input.callID
            )
        }
        do {
            let record = try await store.promote(name: args.trimmedName, scriptPath: args.trimmedScriptPath)
            let content = try AgentToolEncoding.encode(PromoteAgentToolEnvelope(record))
            return .success(content, callID: input.callID)
        } catch let error as AgentToolStoreError {
            return .failure(error.localizedDescription, callID: input.callID)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .failure("Could not promote tool: \(error.localizedDescription)", callID: input.callID)
        }
    }
}

// MARK: - Run tool

/// `tool.run` tool: verifies the pin then executes the script with literal argv.
public struct RunAgentTool: Tool, Sendable {
    /// Stable tool name referenced by the LLM.
    public let name = "tool.run"
    /// When the LLM should use this tool.
    public let description =
        "Runs a promoted agent script by name with optional arguments. "
            + "Use when the owner asks to execute a previously promoted automation. "
            + "The script is verified against its pinned hash before every run; a changed script fails closed. "
            + "Caller arguments append after `--` as literal argv and never touch the pinned script text."
    /// Function-calling contract for the registry name and literal argv.
    public let inputSchema = JSONSchema(
        rawValue: #"{"type":"object","properties":{"#
            + #""name":{"type":"string","description":"Registry name pinned at promotion time"},"#
            + #""argv":{"type":"array","description":"Caller arguments appended after `--` as literal argv","items":{"type":"string"}}},"#
            + #""required":["name"],"additionalProperties":false}"#
    )
    /// Execution spends shell rounds, so every call parks for approval with
    /// graduated trust covering repeats exactly like `bash.exec` repeats.
    public let permissionLevel = PermissionLevel.requiresApproval

    /// Maximum caller arguments per run, bounding command growth without
    /// rejecting ordinary automation that passes a handful of flags.
    public static let maxArgvCount = 64

    /// Durable pin persistence for pre-dispatch verification.
    private let store: AgentToolStore
    /// Shell executor receiving the verified command.
    private let bash: BashTool
    /// Scratch workspace owning the pinned execution directory.
    private let workspace: WorkspaceStore
    /// Single-flight lock serializing runs within one process.
    private let runLock: AgentToolRunLock

    /// Creates a run tool.
    public init(store: AgentToolStore, bash: BashTool, workspace: WorkspaceStore, runLock: AgentToolRunLock = AgentToolRunLock()) {
        self.store = store
        self.bash = bash
        self.workspace = workspace
        self.runLock = runLock
    }

    /// Verifies the pin, stages an immutable copy, then delegates to the shell.
    ///
    /// Verification hashes once and writes those exact bytes to a random
    /// workspace/tmp copy; the shell executes the copy, never the workspace
    /// original, so a concurrent `bash.exec` write to `workspace/tools/`
    /// after verification cannot swap bytes under the running shell. The
    /// eligible tools directory resolves after staging inside the spawn step,
    /// matching the service run route, and the single-flight lock is
    /// held across verification plus spawn so concurrent `tool.run` turns
    /// serialize instead of interleaving verify and spawn, mirroring the
    /// service run route.
    public func execute(input: ToolInput, context: ToolContext) async throws -> ToolOutput {
        let args: RunAgentToolArgs
        do {
            args = try JSONDecoder().decode(RunAgentToolArgs.self, from: Data(input.argumentsJSON.utf8))
        } catch {
            return .failure("Invalid tool.run arguments: expected {\"name\": \"<slug>\", \"argv\": [\"<literal>-proof\", \"args\"]}.", callID: input.callID)
        }
        guard !args.trimmedName.isEmpty else {
            return .failure("Invalid tool.run arguments: 'name' must not be empty.", callID: input.callID)
        }
        let argv = args.effectiveArgv
        guard argv.count <= Self.maxArgvCount else {
            return .failure("Invalid tool.run arguments: 'argv' carries at most \(Self.maxArgvCount) entries (got \(argv.count)).", callID: input.callID)
        }
        if context.dryRun {
            let suffix = argv.isEmpty ? "" : " with \(argv.count) argument(s)"
            return .success("Dry run: would run agent tool '\(args.trimmedName)'\(suffix).", callID: input.callID)
        }
        // Verification plus spawn share one slot so concurrent turns serialize
        // instead of interleaving; the helpers below own acquiring, staging,
        // and spawning while this entry point only routes their outcomes.
        // The eligible tools directory resolves after staging inside the
        // spawn step, matching the service run route.
        let stagedResult = try await lockedStaged(name: args.trimmedName, callID: input.callID)
        switch stagedResult {
        case let .ready(staged, activeID):
            return try await spawnVerified(staged: staged, argv: argv, activeID: activeID, input: input, context: context)
        case let .refusal(output):
            return output
        }
    }

    /// Outcome of locked verification: either the staged pair with its held
    /// slot, or the refusal copy the caller surfaces without spawning.
    private enum LockedStageOutcome: Sendable {
        case ready(StagedAgentTool, UUID)
        case refusal(ToolOutput)
    }

    /// Verifies under the single-flight slot and returns the staged pair.
    ///
    /// The slot is acquired before hashing so a second turn fails fast instead
    /// of paying its own hash plus stage before losing; an unknown name has no
    /// slot, so it falls through to the verifier for the honest not-found copy.
    /// A recycled identifier between preflight and verification re-anchors to
    /// the verified row so the spawn stays single-flight on what will run.
    /// - Parameters:
    ///   - name: Trimmed registry name to verify and stage.
    ///   - callID: Correlation identifier for refusal copies.
    /// - Returns: Staged pair plus the held slot, or the refusal to surface.
    private func lockedStaged(name: String, callID: String) async throws -> LockedStageOutcome {
        var lockedID: UUID?
        do {
            if let preflight = try await store.get(name: name) {
                guard await runLock.tryAcquire(id: preflight.id) else {
                    return .refusal(.failure("Agent tool '\(name)' is already running.", callID: callID))
                }
                lockedID = preflight.id
            }
        } catch let error as AgentToolStoreError {
            return .refusal(.failure(error.localizedDescription, callID: callID))
        } catch {
            // Cancellation propagates as a throw below; any other transport
            // failure surfaces as the honest verification copy.
            if error is CancellationError {
                throw error
            }
            return .refusal(.failure("Could not verify agent tool: \(error.localizedDescription)", callID: callID))
        }
        let staged: StagedAgentTool
        do {
            staged = try await store.verifyAndStage(name: name)
        } catch let error as AgentToolStoreError {
            if let lockedID {
                await runLock.release(id: lockedID)
            }
            return .refusal(.failure(error.localizedDescription, callID: callID))
        } catch {
            if let lockedID {
                await runLock.release(id: lockedID)
            }
            if error is CancellationError {
                throw error
            }
            return .refusal(.failure("Could not verify agent tool: \(error.localizedDescription)", callID: callID))
        }
        var heldID = lockedID
        if let lockedID, staged.record.id != lockedID {
            await runLock.release(id: lockedID)
            guard await runLock.tryAcquire(id: staged.record.id) else {
                AgentToolStore.removeStagedCopy(at: staged.stagedURL)
                return .refusal(.failure("Agent tool '\(name)' is already running.", callID: callID))
            }
            heldID = staged.record.id
        } else if heldID == nil {
            guard await runLock.tryAcquire(id: staged.record.id) else {
                AgentToolStore.removeStagedCopy(at: staged.stagedURL)
                return .refusal(.failure("Agent tool '\(name)' is already running.", callID: callID))
            }
            heldID = staged.record.id
        }
        guard let activeID = heldID else {
            AgentToolStore.removeStagedCopy(at: staged.stagedURL)
            return .refusal(.failure("Agent tool '\(name)' is already running.", callID: callID))
        }
        return .ready(staged, activeID)
    }

    /// Spawns the staged copy and releases the held slot on every path.
    ///
    /// The staged file is removed when this scope exits so verified bytes never
    /// accumulate; the lock releases manually on every path because an actor
    /// hop cannot sit in a defer. A row disabled after staging still refuses
    /// without spawning, and containment re-checks before spawn against a
    /// freshly resolved tools directory, matching the service run route.
    /// - Parameters:
    ///   - staged: Verified row plus its staged copy.
    ///   - argv: Caller arguments appended after `--` as literal argv.
    ///   - activeID: Held single-flight slot to release.
    ///   - input: Original invocation carrying the correlation identifier.
    ///   - context: Execution context carrying approval plus progress.
    /// - Returns: Shell outcome for the staged execution.
    private func spawnVerified(staged: StagedAgentTool, argv: [String], activeID: UUID, input: ToolInput, context: ToolContext) async throws -> ToolOutput {
        defer { AgentToolStore.removeStagedCopy(at: staged.stagedURL) }
        let record = staged.record
        guard record.status == .enabled else {
            await runLock.release(id: activeID)
            return .failure("Agent tool '\(record.name)' is disabled. Re-enable it after review before running.", callID: input.callID)
        }
        // Pin the working directory to the freshly resolved eligible tools
        // directory so every script observes the same bounded cwd regardless
        // of the caller's launch directory; resolving after staging matches
        // the service run route, so a workspace move during verification
        // cannot leave a stale pre-staging directory behind. The script path
        // travels absolute so the shell never resolves it against a
        // caller-controlled cwd.
        // Defense in depth: the store already contained the path at promotion
        // and verification time, but the workspace root may have moved since,
        // so re-check containment before spawning rather than trusting the row.
        let toolsDir = await workspace.root().appendingPathComponent(AgentToolStore.toolsDirectoryName)
        guard AgentToolStore.isContainedInTools(scriptPath: record.scriptPath, toolsDir: toolsDir) else {
            await runLock.release(id: activeID)
            return .failure("Agent tool '\(record.name)' points outside workspace/tools/ and will not run.", callID: input.callID)
        }
        let bashJSON: String
        do {
            bashJSON = try AgentToolStaging.bashInput(stagedURL: staged.stagedURL, argv: argv, cwd: toolsDir.path)
        } catch {
            await runLock.release(id: activeID)
            return .failure("Could not encode agent tool command.", callID: input.callID)
        }
        // The outer `tool.run` approval is the authorization: the inner shell
        // inherits the same approved flag so an already-authorized repeat does
        // not re-park inside the shell while a fresh call still parks outside.
        let bashContext = ToolContext(
            conversationID: context.conversationID,
            dryRun: false,
            approved: context.approved,
            progress: context.progress
        )
        do {
            let output = try await bash.execute(
                input: ToolInput(toolName: bash.name, argumentsJSON: bashJSON, callID: input.callID),
                context: bashContext
            )
            await runLock.release(id: activeID)
            return output
        } catch {
            if error is CancellationError {
                await runLock.release(id: activeID)
                throw error
            }
            await runLock.release(id: activeID)
            return .failure("Agent tool '\(record.name)' failed: \(error.localizedDescription)", callID: input.callID)
        }
    }
}

// MARK: - Factory

/// Factory registering the LLM-invokable agent tools on a `ToolBus`.
public enum AgentTools {
    /// Tool names in registration order.
    public static let toolNames = ["tool.promote", "tool.run"]

    /// Builds the agent tools for a shared pin store, shell, and workspace.
    ///
    /// The tools always build so they stay visible when wired; enablement
    /// lives in the bus toggle while verification (`verify`) owns the
    /// fail-closed execution gate, so a tampered script reports the honest
    /// disabled copy instead of a generic bus-disabled line. Graduated trust
    /// covers `tool.run` repeats through the standard gate path, exactly like
    /// `bash.exec` repeats, because both tools share the `requiresApproval`
    /// tier and the same descriptor accounting.
    /// - Parameters:
    ///   - store: Durable pin persistence shared with the service routes.
    ///   - bash: Shell executor receiving verified commands.
    ///   - workspace: Scratch workspace owning the pinned execution directory.
    ///   - runLock: Single-flight lock serializing runs; the service and the
    ///     direct-core path share one instance per process so concurrent runs
    ///     serialize instead of interleaving verify and spawn.
    /// - Returns: Tools in registration order.
    public static func makeTools(store: AgentToolStore, bash: BashTool, workspace: WorkspaceStore, runLock: AgentToolRunLock = AgentToolRunLock()) -> [any Tool] {
        let promote: any Tool = PromoteAgentTool(store: store)
        let run: any Tool = RunAgentTool(store: store, bash: bash, workspace: workspace, runLock: runLock)
        return [promote, run]
    }

    /// Registers the agent tools, replacing same-named entries.
    public static func register(on bus: ToolBus, store: AgentToolStore, bash: BashTool, workspace: WorkspaceStore, runLock: AgentToolRunLock = AgentToolRunLock()) async {
        for tool in makeTools(store: store, bash: bash, workspace: workspace, runLock: runLock) {
            await bus.register(tool: tool)
        }
    }
}

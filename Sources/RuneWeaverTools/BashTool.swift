// Rune Weaver Tools — Fine-grained sandboxed bash execution tool.
//
// Resource bounds are best-effort `ulimit` guards, not cgroup-grade isolation:
// CPU time (`ulimit -t`) is shared across threads so a threaded child burns the
// budget faster than wall time suggests; address space (`ulimit -v`, RLIMIT_AS)
// over-reports on macOS where shared libraries inflate the count; the
// wall-clock timeout remains the hard backstop that always ends the run.

import Foundation
import os
import RuneWeaverCore

/// Sendable box holding the timeout cancellation task.
/// The caller thread stores the handle while the process termination handler
/// cancels it on an arbitrary queue, so the handle stays behind an unfair lock.
private final class TaskBox: Sendable {
    private let stored = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

    var task: Task<Void, Never>? {
        get { stored.withLock { $0 } }
        set { stored.withLock { $0 = newValue } }
    }
}

/// Wall-clock timeout description for the `bash.exec` JSON schema.
///
/// Single-sourced outside `BashTool` so the schema literal stays within
/// line-length bounds while the decoded JSON bytes stay identical.
private let bashTimeoutSchemaDescription =
    "Optional wall-clock timeout in seconds (1-3600, defaults to bash.timeout_seconds). "
        + "Wall time may exceed CPU time for sleeping processes: sleep-heavy commands accrue "
        + "almost no CPU time against bash.cpu_seconds, so the wall-clock timeout is the bound that ends them. "
        + "Kill reasons are CPU-only: memory-limit deaths (SIGKILL 9/137, ulimit -v malloc failures) stay clean."

/// Declared-hosts description for the `bash.exec` JSON schema.
///
/// Single-sourced outside `BashTool` for the same line-length reason.
private let bashNetworkHostsSchemaDescription =
    "Declared egress hosts for this call (max 10 hostnames or IPs). "
        + "Every host the command dials must be declared here; "
        + "undeclared dials deny even when policy.toml would allow them."

/// Sandbox launch target for one run.
///
/// Replaces the prior 3-tuple so the helper stays within the tuple-size
/// lint budget while keeping executable, arguments, and refusal together.
private struct BashSandboxTarget: Sendable {
    let executableURL: URL?
    let arguments: [String]?
    let failure: ToolOutput?
}

/// Sandbox target inputs for one run.
///
/// Bundles the spawn inputs so the helper stays within the parameter-count
/// lint budget while keeping working directory, command, and tier together.
private struct SandboxTargetRequest: Sendable {
    let workingDirURL: URL?
    let effectiveWorkingDir: URL
    let boundedCommand: String
    let allowNetwork: Bool
    let allowedEgressHosts: [String]
    let additionalReadPaths: [String]
    let callID: String
    let tier: BashSandboxMode
    let workspaceRoot: URL?
}

/// Tool for executing shell commands with granular per-command permissions,
/// strict chaining protection, and optional Seatbelt sandbox confinement.
public struct BashTool: Tool {
    public let name = "bash.exec"
    public let description =
        "Executes a shell command in a sandboxed bash environment with fine-grained permissions. "
            + "Network access is host-scoped: declare destinations in network_hosts (max 10); "
            + "undeclared dial attempts are denied and audited."

    public let inputSchema = JSONSchema(rawValue: """
    {
      "type": "object",
      "properties": {
        "command": {
          "type": "string",
          "description": "The shell command to execute."
        },
        "cwd": {
          "type": "string",
          "description": "Optional working directory for the command."
        },
        "timeoutSeconds": {
          "type": "integer",
          "description": "\(bashTimeoutSchemaDescription)"
        },
        "request_network": {
          "type": "boolean",
          "description": "Optional flag to request network access in Seatbelt sandbox (gates on operator approval)."
        },
        "network_hosts": {
          "type": "array",
          "description": "\(bashNetworkHostsSchemaDescription)",
          "maxItems": 10,
          "items": {"type": "string"}
        }
      },
      "required": ["command"],
      "additionalProperties": false
    }
    """)

    /// Shell execution can mutate state, so every call parks in the approvals
    /// inbox; graduated trust decides whether a repeat target still prompts.
    public let permissionLevel = PermissionLevel.requiresApproval

    /// Shell output can carry file content, network bytes, and injected
    /// directives, so results enter as labeled data.
    public var contentTrustLevel: ContentTrustLevel {
        .untrustedExternal
    }

    public let bashConfig: BashConfig
    public let filesConfig: FilesConfig
    /// Whether a missing platform sandbox may fall back to unsandboxed execution.
    /// Defaults to false so commands never inherit host privileges silently;
    /// bypassing confinement must be a deliberate choice at the construction site.
    public let allowUnsandboxedFallback: Bool
    /// Outbound egress supervisor screening URLs and targets against policy.toml.
    public let egressSupervisor: OutboundEgressSupervisor?
    /// Scratch quotas backing the default working directory and the pre-exec quota gate.
    public let workspaceConfig: WorkspaceConfig
    /// Workspace store owning the default directory; nil derives one from `workspaceConfig`.
    /// Tests inject an isolated store so the default cwd never touches the real home.
    public let workspaceStore: WorkspaceStore?
    /// Injected container seam; nil uses the shared live registry plus live machine client.
    /// Tests inject a hermetic seam so strict plus machine creations never spawn.
    public let containers: ContainerSeam?

    /// Creates a bash execution tool.
    public init(
        bashConfig: BashConfig = BashConfig(),
        filesConfig: FilesConfig = FilesConfig(),
        allowUnsandboxedFallback: Bool = false,
        egressSupervisor: OutboundEgressSupervisor? = nil,
        workspaceConfig: WorkspaceConfig = WorkspaceConfig(),
        workspaceStore: WorkspaceStore? = nil,
        containers: ContainerSeam? = nil
    ) {
        self.bashConfig = bashConfig
        self.filesConfig = filesConfig
        self.allowUnsandboxedFallback = allowUnsandboxedFallback
        self.egressSupervisor = egressSupervisor
        self.workspaceConfig = workspaceConfig
        self.workspaceStore = workspaceStore
        self.containers = containers
    }

    /// Resolves the workspace store for this turn.
    ///
    /// The injected store wins untouched for hermetic tests; otherwise a fresh
    /// store derives from the configured quotas so every turn observes file
    /// config without sharing mutable walk state across turns.
    /// - Returns: Store owning the default working directory.
    var effectiveWorkspaceStore: WorkspaceStore {
        workspaceStore ?? WorkspaceStore(config: workspaceConfig)
    }

    /// Resolves the container runtime for this turn.
    var effectiveContainerRuntime: any ContainerHostRuntime {
        containers?.runtime ?? LiveContainerHostRuntime()
    }

    /// Resolves the strict registry for this turn.
    var effectiveStrictRegistry: StrictTurnRegistry {
        containers?.strictRegistry ?? StrictTurnRegistry.shared
    }

    /// Resolves the machine client for this turn.
    var effectiveMachineClient: MachineContainerClient {
        containers?.machineClient ?? MachineContainerClient.live
    }

    /// Resolves the guest memory cap for container creation.
    var effectiveContainerMemory: String {
        containers?.memory ?? StrictContainerRunner.defaultMemory
    }

    /// Reaps hermetic containers plus scratch, safe after failure, cancellation, or early return.
    public func reapHermeticTestContainers(timeoutSeconds: TimeInterval = 5) async {
        await containers?.strictRegistry.reapAll(timeoutSeconds: timeoutSeconds)
        await (containers?.runtime as? HermeticContainerRuntime)?.reapAll()
        await containers?.machineClient.stopAndRemove(timeoutSeconds: timeoutSeconds)
    }

    public func execute(input: ToolInput, context: ToolContext) async throws -> ToolOutput {
        guard bashConfig.enabled else {
            return .failure("Bash tool is disabled by configuration.", callID: input.callID)
        }
        guard let data = input.argumentsJSON.data(using: .utf8) else {
            return .failure("Invalid arguments for bash.exec: invalid UTF-8 string.", callID: input.callID)
        }
        let args: BashArgs
        do {
            args = try JSONDecoder().decode(BashArgs.self, from: data)
        } catch {
            return .failure("Invalid arguments for bash.exec: failed to parse JSON: \(error.localizedDescription)", callID: input.callID)
        }
        let trimmedCommand = args.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCommand.isEmpty else {
            return .failure("Invalid argument 'command': command must not be empty.", callID: input.callID)
        }
        // Dry-run preview mode takes the same policy plus network gates the
        // live call would, without spawning, so a preview never advertises a
        // target the live call would refuse (mirrors api.request dry runs
        // taking the policy gate without resolving credentials).
        if context.dryRun {
            let decision = BashSecurity.evaluate(command: trimmedCommand, config: bashConfig)
            if decision.isDenied || (decision.requiresApproval && !context.approved) {
                let envelope = BashResultEnvelope(
                    command: trimmedCommand,
                    approvalRequired: decision.requiresApproval,
                    isChained: decision.isChained,
                    denied: decision.isDenied,
                    reason: "Dry run preview: \(decision.reason)"
                )
                return .success(encodeEnvelope(envelope), callID: input.callID)
            }
            if let screeningFailure = await dryRunNetworkFailure(
                command: trimmedCommand,
                args: args,
                decision: decision,
                context: context,
                callID: input.callID
            ) {
                return screeningFailure
            }
            let envelope = BashResultEnvelope(
                command: trimmedCommand,
                approvalRequired: false,
                isChained: decision.isChained,
                denied: false,
                reason: "Dry run preview: \(decision.reason)"
            )
            return .success(encodeEnvelope(envelope), callID: input.callID)
        }
        // Evaluate security policy & chaining protection
        let decision = BashSecurity.evaluate(command: trimmedCommand, config: bashConfig)
        // Deny rule always fails closed. Approval itself rides the permission
        // gate and inbox, never model-supplied arguments.
        if decision.isDenied {
            let envelope = BashResultEnvelope(
                command: trimmedCommand,
                approvalRequired: false,
                isChained: decision.isChained,
                denied: true,
                error: "Command denied by security policy",
                reason: decision.reason
            )
            return .failure(encodeEnvelope(envelope), callID: input.callID)
        }
        // Ask decisions park for human approval via the permission gate and
        // inbox; the tool reports approvalRequired and never executes, so a
        // model-supplied flag cannot self-approve an ask or chained command.
        // An approved context carries the recorded decide authorization and
        // proceeds to execution instead of returning the envelope.
        if decision.requiresApproval, !context.approved {
            let envelope = BashResultEnvelope(
                command: trimmedCommand,
                approvalRequired: true,
                isChained: decision.isChained,
                denied: false,
                error: "Command requires approval: \(decision.reason)",
                reason: decision.reason
            )
            return .failure(encodeEnvelope(envelope), callID: input.callID)
        }
        // Declared egress hosts bound this call's dials.
        let hostsResult = checkedDeclaredHosts(args, callID: input.callID)
        if let hostsFailure = hostsResult.failure {
            return hostsFailure
        }
        let declaredHosts = hostsResult.hosts ?? []
        let validateRoot = await effectiveWorkspaceStore.root()
        if let networkEnvelope = validateNetworkAccess(
            command: trimmedCommand,
            args: args,
            declaredHosts: declaredHosts,
            decision: decision,
            context: context,
            workspaceRoot: validateRoot
        ) {
            return .failure(encodeEnvelope(networkEnvelope), callID: input.callID)
        }
        let tier = BashSandboxRouter.resolveTier(command: trimmedCommand, config: bashConfig)
        return try await executeValidated(
            command: trimmedCommand,
            args: args,
            declaredHosts: declaredHosts,
            context: context,
            callID: input.callID,
            tier: tier
        )
    }
}

extension BashTool {
    /// Runs a validated command through quota, workspace, and sandbox spawn.
    ///
    /// Callers complete decode plus policy gates first; this helper owns the
    /// network screen plus quota plus directory plus timeout plus spawn tail
    /// so `execute` stays within the body-length budget.
    /// - Parameters:
    ///   - command: Trimmed shell command already passing policy gates.
    ///   - args: Decoded tool arguments carrying network and cwd requests.
    ///   - declaredHosts: Canonical hosts bound to this call's dials.
    ///   - context: Turn context carrying approval and session identity.
    ///   - callID: Tool call identifier for output envelopes.
    /// - Returns: Success or failure output for the spawned run.
    private func executeValidated(
        command: String,
        args: BashArgs,
        declaredHosts: [String],
        context: ToolContext,
        callID: String,
        tier: BashSandboxMode
    ) async throws -> ToolOutput {
        let workspace = effectiveWorkspaceStore
        let tierRoot = await workspace.root()
        let baseTier = tier
        // Host fallback stays single-sourced on the router with the live
        // workspace root so approval stamping observes the identical tier execution runs.
        let tier: BashSandboxMode = BashSandboxRouter.applyHostFallback(
            baseTier: baseTier,
            command: command,
            rawCwd: args.cwd,
            workspaceRoot: tierRoot
        )
        let decision = BashSecurity.evaluate(command: command, config: bashConfig)
        let effectiveAllowNetwork = bashConfig.allowNetwork || (args.requestNetwork && context.approved)
        let screenHosts = collectedScreenHosts(in: command)
        let isNetworkCapable = BashNetworkGuard.requiresNetworkAccess(command) || !screenHosts.isEmpty
        if tier != .hostSeatbelt, BashNetworkGuard.requiresNetworkAccess(command), declaredHosts.isEmpty {
            let diagnostic = "Command requires network access but declares no network_hosts;"
                + " declare every dial in network_hosts for isolated tiers."
            let envelope = BashResultEnvelope(
                command: command,
                approvalRequired: false,
                isChained: decision.isChained,
                denied: true,
                error: "Command dials undeclared host(s) with no declared hosts (\(diagnostic))",
                reason: diagnostic
            )
            return .failure(encodeEnvelope(envelope), callID: callID)
        }
        let shouldScreen = BashSandboxRouter.shouldScreenNetwork(
            effectiveAllowNetwork: effectiveAllowNetwork,
            tier: tier,
            isNetworkCapable: isNetworkCapable
        )
        if shouldScreen {
            if let envelope = await screenExplicitURLs(
                command: command,
                declaredHosts: declaredHosts,
                isChained: decision.isChained,
                sessionID: context.sessionID
            ) {
                return .failure(encodeEnvelope(envelope), callID: callID)
            }
        }
        if let quotaFailure = await checkedQuotaFailure(
            workspace: workspace,
            command: command,
            decision: decision,
            callID: callID
        ) {
            return quotaFailure
        }
        let cwdResult = await checkedWorkingDirectory(
            args,
            workspace: workspace,
            command: command,
            decision: decision,
            callID: callID
        )
        if let cwdFailure = cwdResult.failure {
            return cwdFailure
        }
        let timeoutResult = checkedTimeout(args, callID: callID)
        if let timeoutFailure = timeoutResult.failure {
            return timeoutFailure
        }
        let timeout = TimeInterval(timeoutResult.seconds ?? bashConfig.timeoutSeconds)
        switch tier {
        case .strictContainer:
            return try await runStrictContainer(
                command: command,
                timeoutSeconds: timeout,
                effectiveAllowNetwork: effectiveAllowNetwork,
                context: context,
                decision: decision,
                callID: callID,
                requestedCwd: cwdResult.url
            )
        case .machineScoped:
            return try await runMachineScoped(
                command: command,
                timeoutSeconds: timeout,
                effectiveAllowNetwork: effectiveAllowNetwork,
                decision: decision,
                callID: callID,
                requestedCwd: cwdResult.url
            )
        case .hostSeatbelt:
            let workspaceRoot = await workspace.root()
            // The verified agent-tool staged copy lives in workspace/tmp, which
            // sits beside the tools cwd rather than inside it. Allow that one
            // scratch directory for reads so confined shells can map the
            // immutable copy in production (where the workspace sits under home
            // outside the system-temp defaults) without widening writes.
            let workspaceTmpPath = workspaceRoot.appendingPathComponent(WorkspaceStore.tmpDirectoryName).path
            return try await runProcess(
                command: command,
                workingDirURL: cwdResult.url,
                timeoutSeconds: timeout,
                allowNetwork: effectiveAllowNetwork,
                allowedEgressHosts: declaredHosts,
                additionalReadPaths: [workspaceTmpPath],
                callID: callID,
                tier: tier,
                workspaceRoot: workspaceRoot,
                isChained: decision.isChained
            )
        }
    }

    /// Resolves the working directory for a spawned run.
    ///
    /// Isolated tiers never inherit HOME: without an explicit cwd they stay
    /// inside workspace scratch (strict keeps `tmp`, machine keeps the root),
    /// so a missing directory cannot widen the mount. The home fallback only
    /// serves direct callers outside the validated execute path, never masking
    /// a workspace failure in normal turns.
    private func resolveRunWorkingDir(
        workingDirURL: URL?,
        tier: BashSandboxMode,
        workspaceRoot: URL?
    ) -> URL {
        if let workingDirURL {
            return workingDirURL
        }
        if tier != .hostSeatbelt, let workspaceRoot {
            return tier == .strictContainer
                ? BashSandboxRouter.workspaceTmpURL(for: workspaceRoot)
                : workspaceRoot
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// Wraps a model command with clamped resource bounds for one tier.
    ///
    /// Clamping at use keeps a hand-built config from trapping the shell or
    /// inviting OOM swaps; load-time validation already rejects those values
    /// fail-closed, so this is the degrade-to-sane backstop.
    func boundedRunCommand(_ command: String, tier: BashSandboxMode) -> String {
        let clamped = bashConfig.clamped()
        return Self.resourceLimitedCommand(
            command,
            cpuSeconds: clamped.cpuSeconds,
            memoryMB: clamped.memoryMB,
            tier: tier
        )
    }

    /// Wraps a model command with the tier-scoped `ulimit` resource prefix.
    ///
    /// Clamping here keeps direct callers honest even when the stored config
    /// was hand-built past its bounds; the validated file-load path already
    /// rejects those values fail-closed with the dotted field.
    /// - Parameters:
    ///   - command: Model-authored shell command.
    ///   - cpuSeconds: CPU time budget in seconds.
    ///   - memoryMB: Address-space budget in megabytes.
    ///   - tier: Resolved sandbox tier selecting the prefix shape.
    /// - Returns: Prefixed command for `bash -c`.
    public static func resourceLimitedCommand(
        _ command: String,
        cpuSeconds: Int,
        memoryMB: Int,
        tier: BashSandboxMode
    ) -> String {
        let boundedCPU = min(max(cpuSeconds, BashConfig.minCPUSeconds), BashConfig.maxCPUSeconds)
        let boundedMemory = min(max(memoryMB, BashConfig.minMemoryMB), BashConfig.maxMemoryMB)
        return resourcePrefix(cpuSeconds: boundedCPU, memoryMB: boundedMemory, tier: tier) + command
    }

    /// Builds the tier-scoped `ulimit` prefix bounding CPU time and address space.
    ///
    /// The prefix uses `;` (not `&&`) so a failed `ulimit` still runs the
    /// command best-effort instead of refusing it; the wall-clock watchdog
    /// stays the hard backstop regardless. Host shells skip the address-space
    /// bound because shared-library accounting over-reports there and breaks
    /// toolchain spawns, while isolated guests keep both bounds.
    /// - Parameters:
    ///   - cpuSeconds: CPU time budget in seconds, already clamped to 1-3600.
    ///   - memoryMB: Address-space budget in megabytes, already clamped to 64-8192.
    ///   - tier: Resolved sandbox tier selecting the prefix shape.
    /// - Returns: Shell prefix ending in `; `.
    public static func resourcePrefix(cpuSeconds: Int, memoryMB: Int, tier: BashSandboxMode) -> String {
        switch tier {
        case .hostSeatbelt:
            "ulimit -t \(cpuSeconds); "
        case .strictContainer, .machineScoped:
            "ulimit -t \(cpuSeconds); ulimit -v \(memoryMB * 1024); "
        }
    }

    /// Applies sandbox target plus directory and pipes to a fresh process.
    ///
    /// Centralizes executable, arguments, directory, environment, and output
    /// pipes so `runProcess` stays within the body-length budget without
    /// splitting spawn from collection.
    private struct PreparedProcess {
        let process: Process
        let stdoutPipe: Pipe
        let stderrPipe: Pipe
    }

    private func makePreparedProcess(
        sandboxTarget: BashSandboxTarget,
        workingDir: URL,
        tier: BashSandboxMode
    ) -> PreparedProcess {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = sandboxTarget.executableURL
        process.arguments = sandboxTarget.arguments
        process.currentDirectoryURL = workingDir
        process.environment = filteredEnvironment(for: workingDir, tier: tier)
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        return PreparedProcess(process: process, stdoutPipe: stdoutPipe, stderrPipe: stderrPipe)
    }

    private static func startWatchdog(
        timeoutSeconds: TimeInterval,
        process: Process,
        timedOut: OSAllocatedUnfairLock<Bool>
    ) -> Task<Void, Never> {
        Task {
            let boundedTimeoutSeconds = min(max(timeoutSeconds, 1), 3600)
            let nanoseconds = UInt64(boundedTimeoutSeconds * 1_000_000_000)
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            if process.isRunning {
                timedOut.withLock { $0 = true }
                process.terminate()
            }
        }
    }

    private static func makeResultEnvelope(
        command: String,
        isChained: Bool,
        stdout: String,
        stderr: String,
        proc: Process,
        timedOut: Bool
    ) -> BashResultEnvelope {
        let exitCode = proc.terminationStatus
        let killReason = Self.killReason(
            didTimeOut: timedOut,
            terminationReason: proc.terminationReason,
            terminationStatus: proc.terminationStatus,
            stderr: stderr
        )
        return BashResultEnvelope(
            command: command,
            stdout: stdout,
            stderr: stderr,
            exitCode: exitCode,
            approvalRequired: false,
            isChained: isChained,
            denied: false,
            error: exitCode != 0 ? "Command exited with status \(exitCode)" : nil,
            reason: nil,
            killReason: killReason
        )
    }

    private func runProcess(
        command: String,
        workingDirURL: URL?,
        timeoutSeconds: TimeInterval,
        allowNetwork: Bool,
        allowedEgressHosts: [String] = [],
        additionalReadPaths: [String] = [],
        callID: String,
        tier: BashSandboxMode,
        workspaceRoot: URL? = nil,
        isChained: Bool = false
    ) async throws -> ToolOutput {
        let effectiveWorkingDir = resolveRunWorkingDir(
            workingDirURL: workingDirURL,
            tier: tier,
            workspaceRoot: workspaceRoot
        )
        let boundedCommand = boundedRunCommand(command, tier: tier)
        let sandboxTarget = configuredSandboxTarget(
            SandboxTargetRequest(
                workingDirURL: workingDirURL,
                effectiveWorkingDir: effectiveWorkingDir,
                boundedCommand: boundedCommand,
                allowNetwork: allowNetwork,
                allowedEgressHosts: allowedEgressHosts,
                additionalReadPaths: additionalReadPaths,
                callID: callID,
                tier: tier,
                workspaceRoot: workspaceRoot
            )
        )
        if let sandboxFailure = sandboxTarget.failure {
            return sandboxFailure
        }
        let prepared = makePreparedProcess(
            sandboxTarget: sandboxTarget,
            workingDir: effectiveWorkingDir,
            tier: tier
        )
        let process = prepared.process
        let stdoutPipe = prepared.stdoutPipe
        let stderrPipe = prepared.stderrPipe

        // Buffer limit (1 MB max output)
        let maxBytes = 1024 * 1024
        let stdoutBuffer = BashOutputBuffer(maxBytes: maxBytes)
        let stderrBuffer = BashOutputBuffer(maxBytes: maxBytes)

        return try await withCheckedThrowingContinuation { continuation in
            let stdoutHandle = stdoutPipe.fileHandleForReading
            let stderrHandle = stderrPipe.fileHandleForReading

            stdoutHandle.readabilityHandler = { handle in
                stdoutBuffer.append(handle.availableData)
            }

            stderrHandle.readabilityHandler = { handle in
                stderrBuffer.append(handle.availableData)
            }

            let taskBox = TaskBox()
            let timedOut = OSAllocatedUnfairLock<Bool>(initialState: false)
            taskBox.task = Self.startWatchdog(
                timeoutSeconds: timeoutSeconds,
                process: process,
                timedOut: timedOut
            )

            process.terminationHandler = { proc in
                taskBox.task?.cancel()
                stdoutHandle.readabilityHandler = nil
                stderrHandle.readabilityHandler = nil

                stdoutBuffer.append(stdoutHandle.readDataToEndOfFile())
                stderrBuffer.append(stderrHandle.readDataToEndOfFile())

                let envelope = Self.makeResultEnvelope(
                    command: command,
                    isChained: isChained,
                    stdout: stdoutBuffer.stringValue,
                    stderr: stderrBuffer.stringValue,
                    proc: proc,
                    timedOut: timedOut.withLock { $0 }
                )
                let json = encodeEnvelope(envelope)
                if envelope.exitCode == 0 {
                    continuation.resume(returning: .success(json, callID: callID, exitCode: envelope.exitCode))
                } else {
                    continuation.resume(returning: .failure(json, callID: callID, exitCode: envelope.exitCode))
                }
            }

            do {
                try process.run()
            } catch {
                taskBox.task?.cancel()
                stdoutHandle.readabilityHandler = nil
                stderrHandle.readabilityHandler = nil
                continuation.resume(
                    returning: .failure("Failed to spawn process: \(error.localizedDescription)", callID: callID)
                )
            }
        }
    }
}

extension BashTool {
    /// Validates `network_hosts` without touching sandbox or supervisor.
    ///
    /// Thin wrapper over `SeatbeltProfileBuilder.validatedDeclaredHosts` so
    /// shell and desktop share one validity rule; over-limit or malformed
    /// entries refuse before any confinement contact.
    /// - Returns: Hosts plus an optional failure envelope to return directly.
    private func checkedDeclaredHosts(
        _ args: BashArgs,
        callID: String
    ) -> (hosts: [String]?, failure: ToolOutput?) {
        do {
            return try (SeatbeltProfileBuilder.validatedDeclaredHosts(args.networkHosts), nil)
        } catch let error as SeatbeltProfileBuilder.DeclaredHostValidationError {
            return (nil, .failure(error.message, callID: callID))
        } catch {
            return (nil, .failure(error.localizedDescription, callID: callID))
        }
    }

    /// Screens one dry-run preview through declared-hosts plus network access
    /// plus supervisor screening without spawning.
    ///
    /// Mirrors the live gates in `execute` plus `executeValidated` up to (but
    /// not including) quota, workspace, and spawn, so a preview never
    /// advertises a blocked target the live call would refuse. Declared
    /// coverage runs first with the supervisor as the second opinion, and a
    /// missing supervisor denies fail-closed when screening is required;
    /// credential resolution never runs here because bash screening carries
    /// no Keychain values.
    /// - Returns: Failure output to return directly, or nil when the preview
    ///   may proceed.
    private func dryRunNetworkFailure(
        command: String,
        args: BashArgs,
        decision: BashDecision,
        context: ToolContext,
        callID: String
    ) async -> ToolOutput? {
        let hostsResult = checkedDeclaredHosts(args, callID: callID)
        if let hostsFailure = hostsResult.failure {
            return hostsFailure
        }
        let declaredHosts = hostsResult.hosts ?? []
        let workspaceRoot = await effectiveWorkspaceStore.root()
        if let networkEnvelope = validateNetworkAccess(
            command: command,
            args: args,
            declaredHosts: declaredHosts,
            decision: decision,
            context: context,
            workspaceRoot: workspaceRoot
        ) {
            return .failure(encodeEnvelope(networkEnvelope), callID: callID)
        }
        let baseTier = BashSandboxRouter.resolveTier(command: command, config: bashConfig)
        let tier: BashSandboxMode = BashSandboxRouter.applyHostFallback(
            baseTier: baseTier,
            command: command,
            rawCwd: args.cwd,
            workspaceRoot: workspaceRoot
        )
        let effectiveAllowNetwork = bashConfig.allowNetwork || (args.requestNetwork && context.approved)
        let screenHosts = collectedScreenHosts(in: command)
        let isNetworkCapable = BashNetworkGuard.requiresNetworkAccess(command) || !screenHosts.isEmpty
        if tier != .hostSeatbelt, BashNetworkGuard.requiresNetworkAccess(command), declaredHosts.isEmpty {
            let diagnostic = "Command requires network access but declares no network_hosts;"
                + " declare every dial in network_hosts for isolated tiers."
            let envelope = BashResultEnvelope(
                command: command,
                approvalRequired: false,
                isChained: decision.isChained,
                denied: true,
                error: "Command dials undeclared host(s) with no declared hosts (\(diagnostic))",
                reason: diagnostic
            )
            return .failure(encodeEnvelope(envelope), callID: callID)
        }
        let shouldScreen = BashSandboxRouter.shouldScreenNetwork(
            effectiveAllowNetwork: effectiveAllowNetwork,
            tier: tier,
            isNetworkCapable: isNetworkCapable
        )
        if shouldScreen {
            if let envelope = await screenExplicitURLs(
                command: command,
                declaredHosts: declaredHosts,
                isChained: decision.isChained,
                sessionID: context.sessionID
            ) {
                return .failure(encodeEnvelope(envelope), callID: callID)
            }
        }
        return nil
    }

    /// Runs the pre-exec quota gate before spawning.
    ///
    /// Refuses over-quota turns with guidance instead of executing and
    /// growing scratch.
    /// - Returns: Failure envelope, or nil when quota allows execution.
    private func checkedQuotaFailure(
        workspace: WorkspaceStore,
        command: String,
        decision: BashDecision,
        callID: String
    ) async -> ToolOutput? {
        do {
            try await workspace.checkQuota()
            return nil
        } catch {
            let message = if let quotaError = error as? WorkspaceError {
                "Workspace quota exceeded: \(quotaError.reason) Prune workspace/tmp before retrying."
            } else {
                "Workspace quota check failed: \(error.localizedDescription)"
            }
            let envelope = BashResultEnvelope(
                command: command,
                approvalRequired: false,
                isChained: decision.isChained,
                denied: true,
                error: message,
                reason: message
            )
            return .failure(encodeEnvelope(envelope), callID: callID)
        }
    }

    /// Resolves the working directory for one turn.
    ///
    /// An explicit cwd keeps the guard flow so outside-root paths still
    /// refuse with the configured roots named, while the omitted case
    /// ensures the workspace (failing closed on error, never falling back
    /// to home) so every shell starts in bounded scratch. The inside-workspace
    /// fast path resolves symlinks before the prefix check (mirroring
    /// `AgentToolStore.isContainedInTools`), so a symlinked parent such as
    /// `workspace/link -> /tmp` with `cwd: link` falls through to the guard
    /// instead of pinning `currentDirectoryURL` to the symlink and bypassing
    /// `FilesAccessGuard` plus quota/Seatbelt assumptions. Inside-workspace
    /// candidates union the workspace root into the allow roots so hermetic
    /// test workspaces under system temp pass, while deny patterns still
    /// refuse because evaluation checks deny first. The union covers only
    /// the tool's own bounded scratch, never an arbitrary outside path.
    /// - Returns: Directory plus an optional failure envelope to return directly.
    private func checkedWorkingDirectory(
        _ args: BashArgs,
        workspace: WorkspaceStore,
        command: String,
        decision: BashDecision,
        callID: String
    ) async -> (url: URL?, failure: ToolOutput?) {
        let rawCwd = args.cwd?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !rawCwd.isEmpty {
            let workspaceRoot = await workspace.root().standardizedFileURL
            let expandedCwd = (rawCwd as NSString).expandingTildeInPath
            let candidateCwd: URL = if expandedCwd.hasPrefix("/") {
                URL(fileURLWithPath: expandedCwd).standardizedFileURL
            } else {
                workspaceRoot.appendingPathComponent(expandedCwd).standardizedFileURL
            }
            // Resolve symlinks on both sides before the prefix check so a
            // symlinked parent cannot hide an outside target behind an inside
            // spelling; the trailing-slash form keeps `workspace-evil/` from
            // prefix-matching the root. A resolved escape falls through to the
            // guard below, which refuses unless an allowed root covers it.
            let resolvedRoot = workspaceRoot.resolvingSymlinksInPath().standardizedFileURL
            let resolvedCandidate = candidateCwd.resolvingSymlinksInPath().standardizedFileURL
            let insideWorkspace = resolvedCandidate.path == resolvedRoot.path
                || resolvedCandidate.path.hasPrefix(resolvedRoot.path + "/")
            // Workspace-contained candidates union the workspace root into
            // the allow roots so the tool's own bounded scratch passes even
            // when it sits outside the configured roots (for example a
            // hermetic test workspace under system temp), while deny
            // patterns still refuse because evaluation checks deny first.
            // Evaluation uses the absolute canonical path so relative
            // spellings resolve against the workspace root rather than the
            // process directory.
            var effectiveFilesConfig = filesConfig
            if insideWorkspace {
                let workspacePath = resolvedRoot.path
                if !effectiveFilesConfig.allowRoots.contains(workspacePath) {
                    effectiveFilesConfig.allowRoots.append(workspacePath)
                }
            }
            let fileDecision = FilesAccessGuard.evaluate(path: resolvedCandidate.path, filesConfig: effectiveFilesConfig)
            guard fileDecision.allowed else {
                let envelope = BashResultEnvelope(
                    command: command,
                    approvalRequired: fileDecision.requiresApproval,
                    isChained: decision.isChained,
                    denied: true,
                    error: "Working directory access denied:"
                        + " \(fileDecision.reason ?? "outside allowed roots")",
                    reason: fileDecision.reason
                )
                return (nil, .failure(encodeEnvelope(envelope), callID: callID))
            }
            return (URL(fileURLWithPath: fileDecision.resolvedPath), nil)
        } else {
            do {
                return try await (workspace.ensure(), nil)
            } catch {
                let message = if let workspaceError = error as? WorkspaceError {
                    "Workspace unavailable: \(workspaceError.reason)"
                } else {
                    "Workspace unavailable: \(error.localizedDescription)"
                }
                let envelope = BashResultEnvelope(
                    command: command,
                    approvalRequired: false,
                    isChained: decision.isChained,
                    denied: true,
                    error: message,
                    reason: message
                )
                return (nil, .failure(encodeEnvelope(envelope), callID: callID))
            }
        }
    }

    /// Validates the per-invocation timeout inside configured bounds.
    ///
    /// A negative or oversized value cannot trap the sleep conversion below.
    /// - Returns: Seconds plus an optional failure envelope to return directly.
    private func checkedTimeout(
        _ args: BashArgs,
        callID: String
    ) -> (seconds: Int?, failure: ToolOutput?) {
        if let requested = args.timeoutSeconds {
            guard (1 ... 3600).contains(requested) else {
                let message =
                    "Invalid argument 'timeoutSeconds': must be between 1 and 3600"
                        + " (got \(requested))."
                return (nil, .failure(message, callID: callID))
            }
            return (requested, nil)
        } else {
            return (min(max(bashConfig.timeoutSeconds, 1), 3600), nil)
        }
    }
}

extension BashTool {
    /// Sandbox target for one run, configuring executable plus arguments.
    ///
    /// Sandboxed execution stays preferred; the unsandboxed fallback runs
    /// only when the construction site opted in, otherwise the turn refuses
    /// instead of inheriting host privileges. Additional read paths carry
    /// workspace scratch (for example workspace/tmp holding the verified
    /// agent-tool staged copy) so confined shells can map the immutable
    /// copy without widening writes.
    /// - Returns: Executable plus arguments, or a failure to return directly.
    private func configuredSandboxTarget(_ request: SandboxTargetRequest) -> BashSandboxTarget {
        let sandboxExecPath = "/usr/bin/sandbox-exec"
        let isSandboxAvailable = FileManager.default.isExecutableFile(atPath: sandboxExecPath)
        if isSandboxAvailable {
            let profile: String
            if let workspaceRoot = request.workspaceRoot {
                // Single seatbelt contract for every tier: isolated tiers scope
                // to their mounts while the host tier scopes to the working
                // directory, so routing, mounts, and confinement cannot drift.
                // The router already covers workspace scratch, so the extra
                // read paths stay redundant here rather than widening writes.
                // Declared hosts stay blanket-allow in the profile while the
                // supervisor remains the per-host gate, preserving the
                // declared-hosts plus fail-closed posture.
                profile = BashSandboxRouter.seatbeltProfile(
                    for: request.tier,
                    workspaceRoot: workspaceRoot,
                    workingDir: request.workingDirURL ?? request.effectiveWorkingDir,
                    allowNetwork: request.allowNetwork,
                    declaredHosts: request.allowedEgressHosts
                )
            } else {
                let allowedWrites: [String] = if let workingDirURL = request.workingDirURL {
                    SeatbeltProfileBuilder.defaultSystemWritePaths + [workingDirURL.path]
                } else {
                    SeatbeltProfileBuilder.defaultSystemWritePaths
                }
                let builder = SeatbeltProfileBuilder(
                    allowedReadPaths: SeatbeltProfileBuilder.defaultSystemReadPaths
                        + [request.effectiveWorkingDir.path]
                        + request.additionalReadPaths,
                    allowedWritePaths: allowedWrites,
                    deniedPaths: SeatbeltProfileBuilder.defaultDeniedPaths,
                    allowNetwork: request.allowNetwork,
                    allowedEgressHosts: request.allowedEgressHosts
                )
                profile = builder.buildProfile()
            }
            return BashSandboxTarget(
                executableURL: URL(fileURLWithPath: sandboxExecPath),
                arguments: ["-p", profile, "/bin/bash", "-c", request.boundedCommand],
                failure: nil
            )
        } else if allowUnsandboxedFallback {
            return BashSandboxTarget(
                executableURL: URL(fileURLWithPath: "/bin/bash"),
                arguments: ["-c", request.boundedCommand],
                failure: nil
            )
        } else {
            let message = "Sandbox execution unavailable and unsandboxed execution disabled."
            return BashSandboxTarget(executableURL: nil, arguments: nil, failure: .failure(message, callID: request.callID))
        }
    }

    /// Safe filtered environment for one run.
    ///
    /// `PWD` tracks the logical working directory so `pwd` without `-P`
    /// reports the sanctioned path the turn resolved instead of the
    /// kernel's physical `/private/var` spelling.
    /// - Parameter workingDir: Sanctioned directory for this turn.
    /// - Returns: Filtered environment with `PWD` plus the bash marker.
    private func filteredEnvironment(for workingDir: URL, tier: BashSandboxMode) -> [String: String] {
        BashSandboxRouter.scopedEnvironment(for: tier, workingDir: workingDir)
    }

    private func validateNetworkAccess(
        command: String,
        args: BashArgs,
        declaredHosts: [String] = [],
        decision: BashDecision,
        context: ToolContext,
        workspaceRoot: URL? = nil
    ) -> BashResultEnvelope? {
        let requiresNetwork = BashNetworkGuard.requiresNetworkAccess(command)
        if requiresNetwork, !bashConfig.allowNetwork, !args.requestNetwork {
            let diagnostic = "Command requires network access,"
                + " but network access is disabled in Seatbelt sandbox"
                + " (bash.allow_network = false)."
                + " Retry with request_network: true to request operator approval."
            return BashResultEnvelope(
                command: command,
                approvalRequired: false,
                isChained: decision.isChained,
                denied: true,
                error: diagnostic,
                reason: diagnostic
            )
        }
        if args.requestNetwork, !context.approved {
            // The approval card names destinations instead of a blank check:
            // the owner authorizes the declared hosts, not open egress.
            let hostList = declaredHosts.sorted().joined(separator: ", ")
            let hostClause = hostList.isEmpty ? "no declared hosts" : "hosts: \(hostList)"
            // Sandbox copy stays single-sourced so the card, inbox, and
            // dashboard read identical bytes with no command, path, or host
            // interpolation in the summary itself.
            let effectiveRoot = workspaceRoot ?? WorkspaceStore.resolveRoot()
            let tier = BashSandboxRouter.effectiveTier(command: command, config: bashConfig, rawCwd: args.cwd, workspaceRoot: effectiveRoot)
            let sandboxSummary = ApprovalQueue.bashSandboxSummary(
                sandboxMode: tier,
                networkAllowed: bashConfig.allowNetwork || args.requestNetwork
            )
            let diagnostic = "Command requests network access (\(hostClause)) and requires operator approval."
                + " \(sandboxSummary)"
            return BashResultEnvelope(
                command: command,
                approvalRequired: true,
                isChained: decision.isChained,
                denied: false,
                error: diagnostic,
                reason: "request_network enabled (\(hostClause)). \(sandboxSummary)"
            )
        }
        return nil
    }

    /// Screens every dial in a command against declared hosts plus policy.
    ///
    /// Declared coverage runs first so an undeclared dial denies even when the
    /// policy would allow it; the supervisor remains the second opinion on
    /// declared hosts rather than widening them. Denials audit through the
    /// shared tool log so the trail survives the envelope.
    private func screenExplicitURLs(
        command: String,
        declaredHosts: [String] = [],
        isChained: Bool = false,
        sessionID: UUID
    ) async -> BashResultEnvelope? {
        let hosts = collectedScreenHosts(in: command)
        // Fail-closed on missing supervision: this gate runs only when
        // network egress is allowed, so a nil supervisor would otherwise
        // let the command run unscreened. Host-bearing commands deny even
        // if screening widens later.
        guard let supervisor = egressSupervisor else {
            return nilSupervisorEnvelope(command: command, hosts: hosts, isChained: isChained)
        }
        // Declared-hosts gate runs before policy: every screened dial must be
        // declared in `network_hosts`, so a command naming an undeclared host
        // denies even when the policy would allow it.
        let screenedNames = hosts.compactMap(\.url.host).filter { !$0.isEmpty }
        let undeclared = supervisor.checkHosts(screenedNames, against: declaredHosts)
        if !undeclared.isEmpty {
            return undeclaredHostsEnvelope(
                command: command,
                undeclared: Set(undeclared),
                declaredHosts: declaredHosts,
                isChained: isChained
            )
        }
        return await screenedPolicyVerdict(
            command: command,
            hosts: hosts,
            isChained: isChained,
            sessionID: sessionID
        )
    }

    /// Collects explicit plus schemeless hosts for one command.
    ///
    /// Explicit URLs screen individually; the schemeless fallback covers
    /// `curl example.com` spellings with no link match, both resolved
    /// through the approval queue's single-owner extraction.
    /// - Parameter command: Raw shell command.
    /// - Returns: Display plus URL pairs in first-seen order.
    private func collectedScreenHosts(in command: String) -> [(display: String, url: URL)] {
        var hosts: [(display: String, url: URL)] = []
        for rawURL in BashNetworkGuard.extractURLs(from: command) {
            if let parsed = URL(string: rawURL) {
                hosts.append((display: rawURL, url: parsed))
            }
        }
        // Commands mixing explicit links and bare hosts screen every bare
        // host so a second schemeless host cannot run unscreened after
        // the first is approved. Path-embedded names (staged agent copies
        // like `/tmp/.../runeweaver-tool-UUID.sh`) are local file artifacts,
        // never dials, so the router excludes them before screening while a
        // real dial (`curl example.com`) still screens.
        for bareHost in Self.schemelessHosts(in: command) {
            if BashSandboxRouter.isPathEmbeddedHost(bareHost, in: command) {
                continue
            }
            guard let assumed = URL(string: "https://" + bareHost),
                  let assumedHost = assumed.host,
                  !hosts.contains(where: {
                      $0.url.host.map { SensitiveAddressNormalization.normalizedHost($0) }
                          == SensitiveAddressNormalization.normalizedHost(assumedHost)
                  })
            else { continue }
            hosts.append((display: bareHost, url: assumed))
        }
        return hosts
    }

    /// Builds the undeclared-host refusal for one command.
    ///
    /// - Returns: Denied envelope naming the undeclared hosts.
    private func undeclaredHostsEnvelope(
        command: String,
        undeclared: Set<String>,
        declaredHosts: [String],
        isChained: Bool = false
    ) -> BashResultEnvelope {
        let listed = undeclared.sorted().joined(separator: ", ")
        let declared = declaredHosts.sorted().joined(separator: ", ")
        let declaredClause = declared.isEmpty ? "no declared hosts" : "declared: \(declared)"
        RuneWeaverLog.tools.warning(
            "bash.exec denied undeclared host(s) \(listed) (\(declaredClause)) in command: \(command)"
        )
        let diagnostic = "Command dials undeclared host(s) \(listed) not in network_hosts (\(declaredClause))"
        return BashResultEnvelope(
            command: command,
            approvalRequired: false,
            isChained: isChained,
            denied: true,
            error: diagnostic,
            reason: diagnostic
        )
    }

    /// Screens collected hosts against the egress policy.
    ///
    /// One charge per host per command: repeats reuse the verdict instead
    /// of consuming a one-shot grant twice in the same check. A missing
    /// supervisor denies fail-closed: the caller already established
    /// network egress is allowed, so unscreened hosts must not run.
    /// - Returns: Refusal envelope, or nil when every host is allowed.
    private func screenedPolicyVerdict(
        command: String,
        hosts: [(display: String, url: URL)],
        isChained: Bool = false,
        sessionID: UUID
    ) async -> BashResultEnvelope? {
        guard let supervisor = egressSupervisor else {
            return nilSupervisorEnvelope(command: command, hosts: hosts, isChained: isChained)
        }
        var validatedHosts = Set<String>()
        for (display, parsed) in hosts {
            if let host = parsed.host, !host.isEmpty {
                let canonical = SensitiveAddressNormalization.normalizedHost(host)
                if validatedHosts.contains(canonical) {
                    continue
                }
                validatedHosts.insert(canonical)
            }
            let verdict = await supervisor.validate(url: parsed, sessionID: sessionID)
            switch verdict {
            case .allowed:
                break
            case let .denied(reason):
                return BashResultEnvelope(
                    command: command,
                    approvalRequired: false,
                    isChained: isChained,
                    denied: true,
                    error: "Command contains blocked network target '\(display)': \(reason)",
                    reason: reason
                )
            case let .unlistedDomain(host, reason):
                return BashResultEnvelope(
                    command: command,
                    approvalRequired: true,
                    isChained: isChained,
                    denied: true,
                    error: "Command targets unlisted network host '\(host)': \(reason)",
                    reason: reason
                )
            }
        }
        return nil
    }

    /// Builds the fail-closed refusal when egress supervision is missing.
    ///
    /// The screening gate runs only when network egress is allowed, so a
    /// nil supervisor would otherwise let the command run unscreened; the
    /// supervisor stays the second opinion on declared hosts and never
    /// widens them. Host-bearing commands deny even if screening widens
    /// later to cover host-free spells.
    /// - Parameters:
    ///   - command: Raw shell command.
    ///   - hosts: Screened display plus URL pairs already collected.
    /// - Returns: Denied envelope naming the missing supervision.
    private func nilSupervisorEnvelope(
        command: String,
        hosts: [(display: String, url: URL)],
        isChained: Bool = false
    ) -> BashResultEnvelope {
        let screened = hosts.compactMap(\.url.host).filter { !$0.isEmpty }
        let hostClause = screened.isEmpty
            ? "no screened hosts"
            : "screened: \(screened.sorted().joined(separator: ", "))"
        RuneWeaverLog.tools.warning(
            "bash.exec denied (\(hostClause)) without egress supervision in command: \(command)"
        )
        let diagnostic = "Egress supervision unavailable:"
            + " denying network-capable command fail-closed (\(hostClause))."
        return BashResultEnvelope(
            command: command,
            approvalRequired: false,
            isChained: isChained,
            denied: true,
            error: diagnostic,
            reason: diagnostic
        )
    }

    /// Resolves schemeless hosts from a command through single-owner extraction.
    ///
    /// Loops every bare-host match so multi-host commands screen each host
    /// with per-host dedupe at the call site instead of screening only the
    /// first while the second runs unscreened.
    private static func schemelessHosts(in command: String) -> [String] {
        ApprovalQueue.extractAllSchemelessHosts(in: command)
    }

    private func encodeEnvelope(_ envelope: BashResultEnvelope) -> String {
        Self.encodeEnvelope(envelope)
    }
}

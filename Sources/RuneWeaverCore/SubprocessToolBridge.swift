// Rune Weaver Core — Subprocess bridge executing non-native runes via JSON-RPC.

import Foundation
import os

/// A `Tool` implementation that forwards invocations to an out-of-process script or binary.
public struct SubprocessToolBridge: Tool, Sendable {
    public let name: String
    public let description: String
    public let inputSchema: JSONSchema
    public let permissionLevel: PermissionLevel
    public var contentTrustLevel: ContentTrustLevel {
        .untrustedExternal
    }

    /// Plugin identifier owning this tool.
    public let pluginID: String
    /// Directory containing the plugin files.
    public let pluginDirectory: URL
    /// Script or binary path relative to `pluginDirectory`.
    public let entrypoint: String
    /// Execution runtime (.python or .executable).
    public let runtime: PluginRuntime
    /// Timeout in seconds before terminating the subprocess.
    public let timeoutSeconds: TimeInterval
    /// Maximum allowed stdout byte count before the child is killed (defaults to 1 MB).
    public let maxOutputBytes: Int
    /// Explicit opt-out permitting unsandboxed execution when the platform sandbox is missing.
    /// Defaults to false so plugin code never inherits host privileges silently; bypassing
    /// confinement must be a deliberate choice at the construction site.
    public let allowUnsandboxedExecution: Bool
    /// Optional declared capabilities required by the tool.
    public let capabilities: PluginCapabilities?
    /// Optional secrets manager used to resolve declared env variables and sweep output.
    public let secrets: SecretsManager?
    /// Egress evaluator screening declared hosts before spawn.
    public let egressEvaluator: any EgressPolicyEvaluator?
    /// Scaffold plus interpreter-search keys that declared secrets must never overwrite.
    /// Blocked interpreter paths prevent operator secrets from becoming code-loading directives.
    private static let protectedEnvKeys: Set<String> = [
        "PATH", "HOME", "USER", "SHELL", "TMPDIR", "LANG", "LC_ALL", "RUNEWEAVER_PLUGIN",
        "PYTHONPATH", "PYTHONHOME", "LD_PRELOAD", "LD_LIBRARY_PATH",
        "DYLD_INSERT_LIBRARIES", "DYLD_LIBRARY_PATH", "DYLD_FRAMEWORK_PATH", "NODE_OPTIONS"
    ]

    /// Creates a subprocess bridge tool.
    public init(
        pluginID: String,
        declaration: PluginToolDeclaration,
        pluginDirectory: URL,
        entrypoint: String,
        runtime: PluginRuntime,
        permissionOverride: PermissionLevel? = nil,
        capabilities: PluginCapabilities? = nil,
        secrets: SecretsManager? = nil,
        timeoutSeconds: TimeInterval = 30.0,
        maxOutputBytes: Int = 1_048_576,
        allowUnsandboxedExecution: Bool = false,
        egressEvaluator: any EgressPolicyEvaluator? = nil
    ) throws {
        if let permissionOverride, permissionOverride == .trusted {
            throw PluginManifestError.trustedPermissionProhibited(
                tool: declaration.name,
                reason: "External plugins may not be overridden to 'trusted'. Only 'readOnly' and 'requiresApproval' are permitted."
            )
        }
        if declaration.permissionLevel == .trusted {
            throw PluginManifestError.trustedPermissionProhibited(
                tool: declaration.name,
                reason: "External plugins are prohibited from declaring 'trusted' permission level."
            )
        }
        self.pluginID = pluginID
        self.name = declaration.name
        self.description = declaration.description
        self.inputSchema = JSONSchema(rawValue: declaration.inputSchema)
        self.permissionLevel = permissionOverride ?? declaration.permissionLevel
        self.pluginDirectory = pluginDirectory
        self.entrypoint = entrypoint
        self.runtime = runtime
        self.timeoutSeconds = timeoutSeconds
        self.maxOutputBytes = maxOutputBytes
        self.allowUnsandboxedExecution = allowUnsandboxedExecution
        self.capabilities = capabilities ?? declaration.capabilities
        self.secrets = secrets
        self.egressEvaluator = egressEvaluator
    }

    public func execute(input: ToolInput, context: ToolContext) async throws -> ToolOutput {
        try Task.checkCancellation()

        let scriptURL = pluginDirectory.appendingPathComponent(entrypoint)
        // Manifest validation already rejects traversal, but the entrypoint is
        // re-resolved here so a symlinked plugin root or a mutated manifest on
        // disk cannot escape the pen between discovery and execution.
        let normalizedDir = pluginDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        let dirPrefix = normalizedDir.hasSuffix("/") ? normalizedDir : normalizedDir + "/"
        let resolvedScript = scriptURL.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolvedScript.hasPrefix(dirPrefix) else {
            return .failure("Plugin entrypoint escapes its plugin directory.", callID: input.callID)
        }
        // Ignored names stay unhashed, so an entrypoint beneath them would run untracked bytes.
        let resolvedRelative = String(resolvedScript.dropFirst(normalizedDir.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !PluginSecurity.isEntrypointUnderIgnoredPath(entrypoint),
              !PluginSecurity.isEntrypointUnderIgnoredPath(resolvedRelative)
        else {
            return .failure("Plugin entrypoint resolves under an ignored path.", callID: input.callID)
        }
        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            return .failure("Plugin entrypoint not found at '\(entrypoint)'.", callID: input.callID)
        }

        let executableURL: URL
        var arguments: [String] = []

        switch runtime {
        case .python:
            // Prefer virtualenv python if present in plugin directory, otherwise system python3
            let localVenvPython = pluginDirectory.appendingPathComponent(".venv/bin/python3")
            if FileManager.default.isExecutableFile(atPath: localVenvPython.path) {
                executableURL = localVenvPython
            } else {
                executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            }
            arguments = [scriptURL.path]
        case .executable:
            executableURL = scriptURL
        }

        // Construct standard JSON-RPC 2.0 payload
        var rpcParams: [String: Any] = [:]
        if let argsData = input.argumentsJSON.data(using: .utf8),
           let parsedArgs = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any]
        {
            rpcParams = parsedArgs
        }

        let rpcPayload: [String: Any] = [
            "jsonrpc": "2.0",
            "method": name,
            "params": rpcParams,
            "id": input.callID,
            "context": [
                "conversation_id": context.conversationID.uuidString,
                "dry_run": context.dryRun
            ]
        ]

        let requestData: Data
        do {
            requestData = try JSONSerialization.data(withJSONObject: rpcPayload)
        } catch {
            return .failure("Failed to serialize JSON-RPC request for tool '\(name)': \(error.localizedDescription)", callID: input.callID)
        }

        var resolvedSecrets: [String] = []
        var injectedEnv: [String: String] = [:]
        if let envKeys = capabilities?.env {
            for key in envKeys {
                if Self.protectedEnvKeys.contains(key) {
                    continue
                }
                if let secrets {
                    do {
                        guard let val = try await secrets.resolve(key), !val.isEmpty else {
                            continue
                        }
                        injectedEnv[key] = val
                        resolvedSecrets.append(val)
                    } catch {
                        continue
                    }
                }
            }
        }
        if let refusal = await screenDeclaredEgress(callID: input.callID, sessionID: context.sessionID) {
            return refusal
        }

        return try await executeSubprocess(
            executableURL: executableURL,
            arguments: arguments,
            requestData: requestData,
            input: input,
            injectedEnv: injectedEnv,
            resolvedSecrets: resolvedSecrets
        )
    }

    private struct SubprocessInvocation: Sendable {
        let executableURL: URL
        let arguments: [String]
        let workingDirectory: URL
        let inputData: Data
        let callID: String
        let injectedEnv: [String: String]
        let resolvedSecrets: [String]
    }

    private func executeSubprocess(
        executableURL: URL,
        arguments: [String],
        requestData: Data,
        input: ToolInput,
        injectedEnv: [String: String],
        resolvedSecrets: [String]
    ) async throws -> ToolOutput {
        // Track the child in a Sendable box so cancellation reaches the exact process even though
        // the child is spawned on this executor and the cancel handler runs elsewhere.
        let processBox = BoundedProcessRunner.ProcessBox()
        let invocation = SubprocessInvocation(
            executableURL: executableURL,
            arguments: arguments,
            workingDirectory: pluginDirectory,
            inputData: requestData,
            callID: input.callID,
            injectedEnv: injectedEnv,
            resolvedSecrets: resolvedSecrets
        )
        do {
            let output = try await withTaskCancellationHandler {
                let inner = try await runSubprocess(
                    invocation: invocation,
                    processBox: processBox,
                    maxOutputBytes: maxOutputBytes,
                    timeoutSeconds: timeoutSeconds
                )
                // A cancelled turn terminates the child, which resumes as a
                // timeout or exit-code failure; report cancel as cancellation
                // so callers distinguish abort from budget failure.
                try Task.checkCancellation()
                return inner
            } onCancel: {
                processBox.terminateIfRunning()
            }
            try Task.checkCancellation()
            return output
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw error
        }
    }

    private func subprocessSandboxFailure(
        isSandboxAvailable: Bool,
        callID: String
    ) -> ToolOutput? {
        // Refuse before spawning so a missing sandbox never runs unsandboxed
        // by accident; explicit opt-in alone permits the fallback path.
        guard !isSandboxAvailable, !allowUnsandboxedExecution else { return nil }
        RuneWeaverLog.tools.error("SubprocessToolBridge: sandbox-exec unavailable, refusing to execute plugin '\(name)' without sandbox confinement.")
        return .failure("Plugin sandbox unavailable (sandbox-exec missing); execution refused.", callID: callID)
    }

    private func screenDeclaredEgress(callID: String, sessionID: UUID) async -> ToolOutput? {
        // Host-free tools need no screening and still proceed.
        let declared = capabilities?.network ?? []
        guard !declared.isEmpty else { return nil }
        let validated: [String]
        do {
            validated = try SeatbeltProfileBuilder.validatedDeclaredHosts(declared)
        } catch let error as SeatbeltProfileBuilder.DeclaredHostValidationError {
            return .failure(error.message, callID: callID)
        } catch {
            return .failure(error.localizedDescription, callID: callID)
        }
        // Fail-closed without supervision; network tools never run unscreened.
        guard let evaluator = egressEvaluator else {
            RuneWeaverLog.tools.warning("SubprocessToolBridge: denying network-capable plugin '\(name)' without egress supervision.")
            return .failure("Egress supervision unavailable; denying network-capable plugin '\(name)' fail-closed.", callID: callID)
        }
        for host in validated {
            switch await evaluator.evaluateHostStatus(for: host, sessionID: sessionID) {
            case .allowed:
                break
            case let .explicitlyBlocked(reason), let .unlisted(reason):
                return .failure(reason, callID: callID)
            }
        }
        return nil
    }

    private func runSubprocess(
        invocation: SubprocessInvocation,
        processBox: BoundedProcessRunner.ProcessBox,
        maxOutputBytes: Int,
        timeoutSeconds: TimeInterval
    ) async throws -> ToolOutput {
        let sandboxExecPath = "/usr/bin/sandbox-exec"
        let isSandboxAvailable = FileManager.default.isExecutableFile(atPath: sandboxExecPath)
        if let refusal = subprocessSandboxFailure(
            isSandboxAvailable: isSandboxAvailable,
            callID: invocation.callID
        ) {
            return refusal
        }
        // Sendable buffers isolate pipe bytes off the spawning executor so the readability handlers
        // stay @Sendable under strict concurrency.
        let buffers = CappedPipeBuffers()
        let timedOut = OSAllocatedUnfairLock(initialState: false)
        let timeoutTaskStore = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
        let limits = ProcessDrainLimits(stdout: max(1, maxOutputBytes), stderr: 32768)
        let clampedTimeout = max(0.1, timeoutSeconds)
        let budgets = ProcessBudgets(
            timeoutSeconds: timeoutSeconds,
            maxOutputBytes: maxOutputBytes
        )
        let process = prepareProcess(
            invocation: invocation,
            isSandboxAvailable: isSandboxAvailable,
            sandboxExecPath: sandboxExecPath
        )
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        attachSubprocessDrains(
            stdoutPipe: stdoutPipe,
            stderrPipe: stderrPipe,
            buffers: buffers,
            limits: limits,
            processBox: processBox
        )
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ToolOutput, Error>) in
            // Termination is the single resumer; the timeout only latches the
            // flag and terminates so timeout versus cancel stays
            // distinguishable via the outer cancellation check.
            let resumeOnceBox = CheckedOnce<ToolOutput>(continuation)
            process.terminationHandler = { proc in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                let timeoutTask = timeoutTaskStore.withLock { $0 }
                if let timeoutTask {
                    timeoutTask.cancel()
                }
                self.drainSubprocessTail(
                    stdoutPipe: stdoutPipe,
                    stderrPipe: stderrPipe,
                    buffers: buffers,
                    limits: limits
                )
                let output = self.mapSubprocessTermination(
                    terminationStatus: proc.terminationStatus,
                    buffers: buffers,
                    didTimeOut: timedOut.withLock { $0 },
                    budgets: budgets,
                    callID: invocation.callID,
                    resolvedSecrets: invocation.resolvedSecrets
                )
                resumeOnceBox.resume(with: .success(output))
            }
            do {
                try process.run()
                // Publish only after a successful spawn so a launch failure never leaves a dead
                // child for cancellation to chase.
                processBox.set(process)
            } catch {
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                resumeOnceBox.resume(with: .failure(error))
                return
            }
            self.writeSubprocessInput(stdinPipe: stdinPipe, inputData: invocation.inputData)
            let timeoutTask = self.startSubprocessTimeout(
                clampedTimeout: clampedTimeout,
                timedOut: timedOut,
                processBox: processBox
            )
            timeoutTaskStore.withLock { $0 = timeoutTask }
            // The child may have exited before the timeout stored; the handler
            // already cancelled nil, so cancel the stray sleeper now instead of
            // leaving it ticking past settle.
            if !process.isRunning {
                timeoutTask.cancel()
            }
        }
    }
}

// MARK: - Process Preparation

extension SubprocessToolBridge {
    private func prepareProcess(
        invocation: SubprocessInvocation,
        isSandboxAvailable: Bool,
        sandboxExecPath: String
    ) -> Process {
        let process = Process()
        let sandboxExecURL = URL(fileURLWithPath: sandboxExecPath)
        if isSandboxAvailable {
            // Invalid declarations deny network rather than widening scope.
            let declaredHosts = capabilities?.network ?? []
            let validatedHosts: [String]
            do {
                validatedHosts = try SeatbeltProfileBuilder.validatedDeclaredHosts(declaredHosts)
            } catch {
                validatedHosts = []
            }
            // SBPL cannot filter hosts, so the profile stays blanket;
            // OutboundEgressSupervisor remains the sole per-host gate.
            let profile = SeatbeltProfileBuilder(
                allowedReadPaths: [invocation.workingDirectory.path],
                allowedWritePaths: [invocation.workingDirectory.path],
                allowNetwork: !validatedHosts.isEmpty
            ).buildProfile()
            process.executableURL = sandboxExecURL
            process.arguments = ["-p", profile, invocation.executableURL.path] + invocation.arguments
        } else {
            RuneWeaverLog.tools.warning(
                "SubprocessToolBridge: sandbox-exec unavailable, running plugin '\(name)' without sandbox confinement by explicit opt-in."
            )
            process.executableURL = invocation.executableURL
            process.arguments = invocation.arguments
        }
        process.currentDirectoryURL = invocation.workingDirectory

        var env = ProcessInfo.processInfo.environment
        let allowedKeys = ["PATH", "HOME", "USER", "SHELL", "TMPDIR", "LANG", "LC_ALL"]
        env = env.filter { allowedKeys.contains($0.key) }
        env["RUNEWEAVER_PLUGIN"] = "1"
        for (envKey, envValue) in invocation.injectedEnv {
            if Self.protectedEnvKeys.contains(envKey) {
                continue
            }
            env[envKey] = envValue
        }
        process.environment = env
        return process
    }
}

// MARK: - Response Parsing

extension SubprocessToolBridge {
    func parseSubprocessResponse(
        stdoutData: Data,
        stderrData: Data,
        terminationStatus: Int32,
        maxOutputBytes: Int,
        callID: String,
        resolvedSecrets: [String] = []
    ) -> ToolOutput {
        if terminationStatus != 0 {
            let rawErrText = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let errText = resolvedSecrets.isEmpty ? rawErrText : SecretsManager.sweepResolved(rawErrText, secrets: resolvedSecrets)
            let message = errText.isEmpty ? "Process exited with code \(terminationStatus)." : errText
            return .failure(message, callID: callID)
        }

        let boundedData = stdoutData.prefix(maxOutputBytes)
        guard let rawStdoutStr = String(data: boundedData, encoding: .utf8) else {
            return .failure("Tool returned invalid non-UTF8 output.", callID: callID)
        }
        let stdoutStr = resolvedSecrets.isEmpty ? rawStdoutStr : SecretsManager.sweepResolved(rawStdoutStr, secrets: resolvedSecrets)

        // Parse JSON-RPC 2.0 response
        if let parsed = try? JSONSerialization.jsonObject(with: boundedData) as? [String: Any] {
            if let errorObj = parsed["error"] as? [String: Any],
               let rawErrMsg = errorObj["message"] as? String
            {
                let errMsg = resolvedSecrets.isEmpty ? rawErrMsg : SecretsManager.sweepResolved(rawErrMsg, secrets: resolvedSecrets)
                return .failure(errMsg, callID: callID)
            }
            if let result = parsed["result"] {
                var content: String = if let str = result as? String {
                    str
                } else if let dict = result as? [String: Any],
                          let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
                          let str = String(data: data, encoding: .utf8)
                {
                    str
                } else {
                    String(describing: result)
                }
                if !resolvedSecrets.isEmpty {
                    content = SecretsManager.sweepResolved(content, secrets: resolvedSecrets)
                }
                return .success(content, callID: callID)
            }
        }

        // Fallback to raw stdout if not structured JSON-RPC
        return .success(stdoutStr.trimmingCharacters(in: .whitespacesAndNewlines), callID: callID)
    }
}

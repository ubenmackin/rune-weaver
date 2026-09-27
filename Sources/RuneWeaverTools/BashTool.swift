// Rune Weaver Tools — Fine-grained sandboxed bash execution tool.

import Foundation
import os
import RuneWeaverCore

/// Arguments for `bash.exec`.
public struct BashArgs: Codable, Sendable, Equatable {
    /// Shell command string to execute.
    public let command: String
    /// Working directory for execution (optional).
    public let cwd: String?
    /// Execution timeout in seconds (optional).
    public let timeoutSeconds: Int?

    public init(
        command: String,
        cwd: String? = nil,
        timeoutSeconds: Int? = nil
    ) {
        self.command = command
        self.cwd = cwd
        self.timeoutSeconds = timeoutSeconds
    }
}

/// JSON payload returned in `ToolOutput.content` for `bash.exec`.
public struct BashResultEnvelope: Codable, Sendable, Equatable {
    public let command: String
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
    public let approvalRequired: Bool
    public let isChained: Bool
    public let denied: Bool
    public let error: String?
    public let reason: String?

    public init(
        command: String,
        stdout: String = "",
        stderr: String = "",
        exitCode: Int32 = 0,
        approvalRequired: Bool = false,
        isChained: Bool = false,
        denied: Bool = false,
        error: String? = nil,
        reason: String? = nil
    ) {
        self.command = command
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.approvalRequired = approvalRequired
        self.isChained = isChained
        self.denied = denied
        self.error = error
        self.reason = reason
    }
}

/// Thread-safe capped output buffer for process stdout/stderr streams.
final class BashOutputBuffer: Sendable {
    private struct State: Sendable {
        var data = Data()
        let maxBytes: Int
    }

    private let state: OSAllocatedUnfairLock<State>

    init(maxBytes: Int = 1024 * 1024) {
        self.state = OSAllocatedUnfairLock(initialState: State(data: Data(), maxBytes: maxBytes))
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        state.withLock { buffer in
            if buffer.data.count < buffer.maxBytes {
                buffer.data.append(chunk.prefix(buffer.maxBytes - buffer.data.count))
            }
        }
    }

    var stringValue: String {
        state.withLock { buffer in
            String(data: buffer.data, encoding: .utf8) ?? ""
        }
    }
}

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

/// Tool for executing shell commands with granular per-command permissions,
/// strict chaining protection, and optional Seatbelt sandbox confinement.
public struct BashTool: Tool {
    public let name = "bash.exec"
    public let description = "Executes a shell command in a sandboxed bash environment with fine-grained permissions."

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
          "description": "Optional timeout in seconds."
        }
      },
      "required": ["command"]
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

    /// Creates a bash execution tool.
    public init(
        bashConfig: BashConfig = BashConfig(),
        filesConfig: FilesConfig = FilesConfig(),
        allowUnsandboxedFallback: Bool = false
    ) {
        self.bashConfig = bashConfig
        self.filesConfig = filesConfig
        self.allowUnsandboxedFallback = allowUnsandboxedFallback
    }

    public func execute(input: ToolInput, context: ToolContext) async throws -> ToolOutput {
        guard bashConfig.enabled else {
            return .failure("Bash tool is disabled by configuration.", callID: input.callID)
        }

        let decoder = JSONDecoder()
        guard let data = input.argumentsJSON.data(using: .utf8),
              let args = try? decoder.decode(BashArgs.self, from: data)
        else {
            return .failure("Invalid arguments for bash.exec: failed to parse JSON.", callID: input.callID)
        }

        let trimmedCommand = args.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCommand.isEmpty else {
            return .failure("Invalid argument 'command': command must not be empty.", callID: input.callID)
        }

        // Dry-run preview mode
        if context.dryRun {
            let decision = BashSecurity.evaluate(command: trimmedCommand, config: bashConfig)
            let envelope = BashResultEnvelope(
                command: trimmedCommand,
                approvalRequired: decision.requiresApproval,
                isChained: decision.isChained,
                denied: decision.isDenied,
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
        if decision.requiresApproval {
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

        // Validate cwd if supplied
        var workingDirURL: URL?
        if let rawCwd = args.cwd?.trimmingCharacters(in: .whitespacesAndNewlines), !rawCwd.isEmpty {
            let fileDecision = FilesAccessGuard.evaluate(path: rawCwd, filesConfig: filesConfig)
            guard fileDecision.allowed else {
                let envelope = BashResultEnvelope(
                    command: trimmedCommand,
                    approvalRequired: fileDecision.requiresApproval,
                    denied: true,
                    error: "Working directory access denied: \(fileDecision.reason ?? "outside allowed roots")",
                    reason: fileDecision.reason
                )
                return .failure(encodeEnvelope(envelope), callID: input.callID)
            }
            workingDirURL = URL(fileURLWithPath: fileDecision.resolvedPath)
        }

        // Per-invocation timeout stays inside the configured bounds so a
        // negative or oversized value cannot trap the sleep conversion below.
        let validatedTimeoutSeconds: Int
        if let requested = args.timeoutSeconds {
            guard (1 ... 3600).contains(requested) else {
                return .failure(
                    "Invalid argument 'timeoutSeconds': must be between 1 and 3600 (got \(requested)).",
                    callID: input.callID
                )
            }
            validatedTimeoutSeconds = requested
        } else {
            validatedTimeoutSeconds = min(max(bashConfig.timeoutSeconds, 1), 3600)
        }

        // Execute command
        let timeout = TimeInterval(validatedTimeoutSeconds)
        return try await runProcess(
            command: trimmedCommand,
            workingDirURL: workingDirURL,
            timeoutSeconds: timeout,
            callID: input.callID
        )
    }

    private func runProcess(
        command: String,
        workingDirURL: URL?,
        timeoutSeconds: TimeInterval,
        callID: String
    ) async throws -> ToolOutput {
        let sandboxExecPath = "/usr/bin/sandbox-exec"
        let isSandboxAvailable = FileManager.default.isExecutableFile(atPath: sandboxExecPath)

        let process = Process()
        let effectiveWorkingDir = workingDirURL ?? FileManager.default.homeDirectoryForCurrentUser

        if isSandboxAvailable {
            let profileBuilder = SeatbeltProfileBuilder(
                allowedReadPaths: SeatbeltProfileBuilder.defaultSystemReadPaths + [effectiveWorkingDir.path],
                allowedWritePaths: SeatbeltProfileBuilder.defaultSystemWritePaths + [effectiveWorkingDir.path],
                deniedPaths: SeatbeltProfileBuilder.defaultDeniedPaths,
                allowNetwork: bashConfig.allowNetwork
            )
            let profile = profileBuilder.buildProfile()
            process.executableURL = URL(fileURLWithPath: sandboxExecPath)
            process.arguments = ["-p", profile, "/bin/bash", "-c", command]
        } else if allowUnsandboxedFallback {
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-c", command]
        } else {
            return .failure("Sandbox execution unavailable and unsandboxed execution disabled.", callID: callID)
        }

        process.currentDirectoryURL = effectiveWorkingDir

        // Safe filtered environment
        var env = ProcessInfo.processInfo.environment
        let allowedKeys = ["PATH", "HOME", "USER", "SHELL", "TMPDIR", "LANG", "LC_ALL", "TERM"]
        env = env.filter { allowedKeys.contains($0.key) }
        env["RUNEWEAVER_BASH"] = "1"
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

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
            taskBox.task = Task {
                // Bounds were validated before dispatch; clamp again so the
                // nanosecond conversion below cannot trap on out-of-range input.
                let boundedTimeoutSeconds = min(max(timeoutSeconds, 1), 3600)
                let nanoseconds = UInt64(boundedTimeoutSeconds * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
                if process.isRunning {
                    process.terminate()
                }
            }

            process.terminationHandler = { proc in
                taskBox.task?.cancel()
                stdoutHandle.readabilityHandler = nil
                stderrHandle.readabilityHandler = nil

                stdoutBuffer.append(stdoutHandle.readDataToEndOfFile())
                stderrBuffer.append(stderrHandle.readDataToEndOfFile())

                let finalOut = stdoutBuffer.stringValue
                let finalErr = stderrBuffer.stringValue

                let exitCode = proc.terminationStatus
                let envelope = BashResultEnvelope(
                    command: command,
                    stdout: finalOut,
                    stderr: finalErr,
                    exitCode: exitCode,
                    approvalRequired: false,
                    isChained: false,
                    denied: false,
                    error: exitCode != 0 ? "Command exited with status \(exitCode)" : nil,
                    reason: nil
                )

                let json = encodeEnvelope(envelope)
                if exitCode == 0 {
                    continuation.resume(returning: .success(json, callID: callID))
                } else {
                    continuation.resume(returning: .failure(json, callID: callID))
                }
            }

            do {
                try process.run()
            } catch {
                taskBox.task?.cancel()
                stdoutHandle.readabilityHandler = nil
                stderrHandle.readabilityHandler = nil
                continuation.resume(returning: .failure("Failed to spawn process: \(error.localizedDescription)", callID: callID))
            }
        }
    }

    private func encodeEnvelope(_ envelope: BashResultEnvelope) -> String {
        Self.encodeEnvelope(envelope)
    }

    public static func encodeEnvelope(_ envelope: BashResultEnvelope) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(envelope), let str = String(data: data, encoding: .utf8) {
            return str
        }
        return """
        {"command":"\(envelope.command)","exitCode":\(envelope.exitCode),"stdout":"\(envelope.stdout)","stderr":"\(envelope.stderr)"}
        """
    }
}

// Rune Weaver Core — Subprocess bridge executing non-native runes via JSON-RPC.

import Foundation
import os

/// A `Tool` implementation that forwards invocations to an out-of-process script or binary.
public struct SubprocessToolBridge: Tool, Sendable {
    public let name: String
    public let description: String
    public let inputSchema: JSONSchema
    public let permissionLevel: PermissionLevel

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

    /// Creates a subprocess bridge tool.
    public init(
        pluginID: String,
        declaration: PluginToolDeclaration,
        pluginDirectory: URL,
        entrypoint: String,
        runtime: PluginRuntime,
        permissionOverride: PermissionLevel? = nil,
        timeoutSeconds: TimeInterval = 30.0,
        maxOutputBytes: Int = 1_048_576,
        allowUnsandboxedExecution: Bool = false
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

        guard let requestData = try? JSONSerialization.data(withJSONObject: rpcPayload) else {
            return .failure("Failed to serialize JSON-RPC request for tool '\(name)'.", callID: input.callID)
        }

        return try await executeSubprocess(
            executableURL: executableURL,
            arguments: arguments,
            requestData: requestData,
            input: input
        )
    }

    private struct SubprocessInvocation {
        let executableURL: URL
        let arguments: [String]
        let workingDirectory: URL
        let inputData: Data
        let callID: String
    }

    private func executeSubprocess(
        executableURL: URL,
        arguments: [String],
        requestData: Data,
        input: ToolInput
    ) async throws -> ToolOutput {
        // Track the child in a Sendable box so cancellation reaches it even when the Process is
        // created on a background queue inside runSubprocess. Without this box a cancelled turn
        // would leak the subprocess until the timeout fires.
        let processBox = ProcessBox()
        let invocation = SubprocessInvocation(
            executableURL: executableURL,
            arguments: arguments,
            workingDirectory: pluginDirectory,
            inputData: requestData,
            callID: input.callID
        )
        return try await withTaskCancellationHandler {
            try await runSubprocess(
                invocation: invocation,
                processBox: processBox,
                maxOutputBytes: maxOutputBytes,
                timeoutSeconds: timeoutSeconds
            )
        } onCancel: {
            processBox.terminate()
        }
    }

    private func prepareProcess(
        invocation: SubprocessInvocation,
        isSandboxAvailable: Bool,
        sandboxExecPath: String
    ) -> Process {
        let process = Process()
        let sandboxExecURL = URL(fileURLWithPath: sandboxExecPath)
        if isSandboxAvailable {
            let profile = SeatbeltProfileBuilder(
                allowedReadPaths: [invocation.workingDirectory.path],
                allowedWritePaths: [invocation.workingDirectory.path],
                allowNetwork: false
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
        process.environment = env
        return process
    }

    private func runSubprocess(
        invocation: SubprocessInvocation,
        processBox: ProcessBox,
        maxOutputBytes: Int,
        timeoutSeconds: TimeInterval
    ) async throws -> ToolOutput {
        let allowUnsandboxed = allowUnsandboxedExecution
        let toolName = name
        let sandboxExecPath = "/usr/bin/sandbox-exec"
        let isSandboxAvailable = FileManager.default.isExecutableFile(atPath: sandboxExecPath)
        if !isSandboxAvailable, !allowUnsandboxed {
            RuneWeaverLog.tools.error("SubprocessToolBridge: sandbox-exec unavailable, refusing to execute plugin '\(toolName)' without sandbox confinement.")
            return .failure("Plugin sandbox unavailable (sandbox-exec missing); execution refused.", callID: invocation.callID)
        }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
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
                processBox.set(process)

                let resumeOnceBox = SubprocessResumeOnce(continuation)

                // Timeout timer
                let timeoutItem = DispatchWorkItem {
                    if process.isRunning {
                        process.terminate()
                    }
                    resumeOnceBox.resume(with: .success(.failure(
                        "Tool execution timed out after \(Int(timeoutSeconds))s.",
                        callID: invocation.callID
                    )))
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: timeoutItem)

                do {
                    try process.run()

                    let drainGroup = DispatchGroup()
                    let stdoutDrain = BoundedDrain()
                    let stderrDrain = BoundedDrain()
                    let outFD = stdoutPipe.fileHandleForReading.fileDescriptor
                    let errFD = stderrPipe.fileHandleForReading.fileDescriptor

                    // Concurrently drain stdout and stderr so a child producing large
                    // stderr output does not fill the OS pipe buffer and deadlock while
                    // Swift blocks waiting for stdout EOF.
                    drainGroup.enter()
                    DispatchQueue.global(qos: .userInitiated).async {
                        let res = boundedRead(fileDescriptor: outFD, limit: maxOutputBytes, process: process)
                        stdoutDrain.set(res)
                        drainGroup.leave()
                    }

                    drainGroup.enter()
                    DispatchQueue.global(qos: .userInitiated).async {
                        let res = boundedRead(fileDescriptor: errFD, limit: 32768, process: process)
                        stderrDrain.set(res)
                        drainGroup.leave()
                    }

                    do {
                        try stdinPipe.fileHandleForWriting.write(contentsOf: invocation.inputData)
                        try stdinPipe.fileHandleForWriting.write(contentsOf: Data("\n".utf8))
                    } catch {
                        RuneWeaverLog.tools.warning("SubprocessToolBridge: stdin write terminated early: \(error)")
                        // The child may have exited or closed stdin prematurely; handle reading handles EOF cleanly.
                    }
                    try? stdinPipe.fileHandleForWriting.close()

                    process.waitUntilExit()
                    drainGroup.wait()
                    timeoutItem.cancel()

                    let stdoutResult = stdoutDrain.get()
                    let stderrResult = stderrDrain.get()

                    if stdoutResult.didExceed {
                        resumeOnceBox.resume(with: .success(.failure(
                            "Tool output exceeded the \(maxOutputBytes)-byte limit and was terminated.",
                            callID: invocation.callID
                        )))
                        return
                    }

                    let output = parseSubprocessResponse(
                        stdoutData: stdoutResult.data,
                        stderrData: stderrResult.data,
                        terminationStatus: process.terminationStatus,
                        maxOutputBytes: maxOutputBytes,
                        callID: invocation.callID
                    )
                    resumeOnceBox.resume(with: .success(output))
                } catch {
                    timeoutItem.cancel()
                    resumeOnceBox.resume(with: .failure(error))
                }
            }
        }
    }

    private func parseSubprocessResponse(
        stdoutData: Data,
        stderrData: Data,
        terminationStatus: Int32,
        maxOutputBytes: Int,
        callID: String
    ) -> ToolOutput {
        if terminationStatus != 0 {
            let errText = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let message = errText.isEmpty ? "Process exited with code \(terminationStatus)." : errText
            return .failure(message, callID: callID)
        }

        let boundedData = stdoutData.prefix(maxOutputBytes)
        guard let stdoutStr = String(data: boundedData, encoding: .utf8) else {
            return .failure("Tool returned invalid non-UTF8 output.", callID: callID)
        }

        // Parse JSON-RPC 2.0 response
        if let parsed = try? JSONSerialization.jsonObject(with: boundedData) as? [String: Any] {
            if let errorObj = parsed["error"] as? [String: Any],
               let errMsg = errorObj["message"] as? String
            {
                return .failure(errMsg, callID: callID)
            }
            if let result = parsed["result"] {
                let content: String = if let str = result as? String {
                    str
                } else if let dict = result as? [String: Any],
                          let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
                          let str = String(data: data, encoding: .utf8)
                {
                    str
                } else {
                    String(describing: result)
                }
                return .success(content, callID: callID)
            }
        }

        // Fallback to raw stdout if not structured JSON-RPC
        return .success(stdoutStr.trimmingCharacters(in: .whitespacesAndNewlines), callID: callID)
    }
}

/// One-shot gate ensuring a subprocess continuation resumes exactly once.
private final class SubprocessResumeOnce: Sendable {
    private struct State: Sendable {
        var continuation: CheckedContinuation<ToolOutput, Error>?
        var didResume = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Creates a gate holding a continuation.
    /// - Parameter continuation: Continuation to resume once.
    init(_ continuation: CheckedContinuation<ToolOutput, Error>) {
        state.withLock { $0.continuation = continuation }
    }

    /// Resumes the held continuation unless already resumed.
    /// - Parameter result: Result to resume with.
    func resume(with result: Result<ToolOutput, Error>) {
        let continuation = state.withLock { lockState -> CheckedContinuation<ToolOutput, Error>? in
            guard !lockState.didResume else { return nil }
            lockState.didResume = true
            let held = lockState.continuation
            lockState.continuation = nil
            return held
        }
        continuation?.resume(with: result)
    }
}

/// Shares the live child across the cancellation handler and the worker queue
/// so a cancelled turn can terminate the exact process that is producing output.
private final class ProcessBox: Sendable {
    private let boxed = OSAllocatedUnfairLock<Process?>(initialState: nil)

    func set(_ process: Process) {
        boxed.withLock { $0 = process }
    }

    func terminate() {
        let process = boxed.withLock { $0 }
        if let process, process.isRunning {
            process.terminate()
        }
    }
}

/// Outcome of an incremental capped read.
private struct BoundedReadResult: Sendable {
    let data: Data
    let didExceed: Bool
}

/// Reads a pipe in small chunks and kills the child as soon as the cap is
/// passed, keeping a malicious rune from forcing a multi-gigabyte allocation
/// before any truncation could run.
private func boundedRead(fileDescriptor: Int32, limit: Int, process: Process) -> BoundedReadResult {
    let handle = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: false)
    var accumulated = Data()
    let chunkSize = 16384

    while true {
        let chunk: Data
        do {
            if let readData = try handle.read(upToCount: chunkSize) {
                chunk = readData
            } else {
                break
            }
        } catch {
            break
        }

        if chunk.isEmpty {
            break
        }

        accumulated.append(chunk)
        if accumulated.count > limit {
            if process.isRunning {
                process.terminate()
            }
            return BoundedReadResult(data: accumulated, didExceed: true)
        }
    }
    return BoundedReadResult(data: accumulated, didExceed: false)
}

/// Thread-safe accumulator for concurrent pipe draining.
private final class BoundedDrain: Sendable {
    private let result = OSAllocatedUnfairLock(initialState: BoundedReadResult(data: Data(), didExceed: false))

    func set(_ newResult: BoundedReadResult) {
        result.withLock { $0 = newResult }
    }

    func get() -> BoundedReadResult {
        result.withLock { $0 }
    }
}

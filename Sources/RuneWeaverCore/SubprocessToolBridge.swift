// Rune Weaver Core — Subprocess bridge executing non-native runes via JSON-RPC.
//
// Wraps Python scripts and external binaries in an isolated child process communicating
// via JSON-RPC 2.0 over stdin/stdout. Sanitizes environment variables, enforces timeouts,
// caps maximum output size, and terminates orphaned child processes on turn cancellation.

import Foundation

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

    /// Creates a subprocess bridge tool.
    ///
    /// External runes can never resolve to `trusted`: attempts throw instead
    /// of producing a silently escalated tool.
    public init(
        pluginID: String,
        declaration: PluginToolDeclaration,
        pluginDirectory: URL,
        entrypoint: String,
        runtime: PluginRuntime,
        permissionOverride: PermissionLevel? = nil,
        timeoutSeconds: TimeInterval = 30.0,
        maxOutputBytes: Int = 1_048_576
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
        // Track the child in a Sendable box so cancellation reaches it even when
        // the Process is created on a background queue inside runSubprocess.
        // Without this box a cancelled turn would leak the subprocess until the
        // timeout fires.
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

    private func runSubprocess(
        invocation: SubprocessInvocation,
        processBox: ProcessBox,
        maxOutputBytes: Int,
        timeoutSeconds: TimeInterval
    ) async throws -> ToolOutput {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = invocation.executableURL
                process.arguments = invocation.arguments
                process.currentDirectoryURL = invocation.workingDirectory

                // Sanitize environment: do not leak Keychain or host ambient credentials
                var env = ProcessInfo.processInfo.environment
                let allowedKeys = ["PATH", "HOME", "USER", "SHELL", "TMPDIR", "LANG", "LC_ALL"]
                env = env.filter { allowedKeys.contains($0.key) }
                env["RUNEWEAVER_PLUGIN"] = "1"
                process.environment = env

                let stdinPipe = Pipe()
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()

                process.standardInput = stdinPipe
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe
                processBox.set(process)

                var didResume = false
                let lock = NSLock()

                let resumeOnce: (Result<ToolOutput, Error>) -> Void = { result in
                    lock.lock()
                    defer { lock.unlock() }
                    guard !didResume else { return }
                    didResume = true
                    continuation.resume(with: result)
                }

                // Timeout timer
                let timeoutItem = DispatchWorkItem {
                    if process.isRunning {
                        process.terminate()
                    }
                    resumeOnce(.success(.failure(
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
                    let outHandle = SendableHandle(stdoutPipe.fileHandleForReading)
                    let errHandle = SendableHandle(stderrPipe.fileHandleForReading)

                    // Concurrently drain stdout and stderr so a child producing large
                    // stderr output does not fill the OS pipe buffer and deadlock while
                    // Swift blocks waiting for stdout EOF.
                    drainGroup.enter()
                    DispatchQueue.global(qos: .userInitiated).async {
                        let res = boundedRead(handle: outHandle.handle, limit: maxOutputBytes, process: process)
                        stdoutDrain.set(res)
                        drainGroup.leave()
                    }

                    drainGroup.enter()
                    DispatchQueue.global(qos: .userInitiated).async {
                        let res = boundedRead(handle: errHandle.handle, limit: 32768, process: process)
                        stderrDrain.set(res)
                        drainGroup.leave()
                    }

                    do {
                        try stdinPipe.fileHandleForWriting.write(contentsOf: invocation.inputData)
                        try stdinPipe.fileHandleForWriting.write(contentsOf: Data("\n".utf8))
                    } catch {
                        // The child may have exited or closed stdin prematurely; handle reading handles EOF cleanly.
                    }
                    try? stdinPipe.fileHandleForWriting.close()

                    process.waitUntilExit()
                    drainGroup.wait()
                    timeoutItem.cancel()

                    let stdoutResult = stdoutDrain.get()
                    let stderrResult = stderrDrain.get()

                    if stdoutResult.didExceed {
                        resumeOnce(.success(.failure(
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
                    resumeOnce(.success(output))
                } catch {
                    timeoutItem.cancel()
                    resumeOnce(.failure(error))
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

/// Shares the live child across the cancellation handler and the worker queue
/// so a cancelled turn can terminate the exact process that is producing output.
private final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var boxed: Process?

    func set(_ process: Process) {
        lock.lock()
        defer { lock.unlock() }
        boxed = process
    }

    func terminate() {
        lock.lock()
        defer { lock.unlock() }
        if let boxed, boxed.isRunning {
            boxed.terminate()
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
private func boundedRead(handle: FileHandle, limit: Int, process: Process) -> BoundedReadResult {
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

/// Sendable wrapper for FileHandle across concurrent dispatch queues.
private final class SendableHandle: @unchecked Sendable {
    let handle: FileHandle
    init(_ handle: FileHandle) {
        self.handle = handle
    }
}

/// Thread-safe accumulator for concurrent pipe draining.
private final class BoundedDrain: @unchecked Sendable {
    private let lock = NSLock()
    private var result = BoundedReadResult(data: Data(), didExceed: false)

    func set(_ newResult: BoundedReadResult) {
        lock.lock()
        defer { lock.unlock() }
        result = newResult
    }

    func get() -> BoundedReadResult {
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}

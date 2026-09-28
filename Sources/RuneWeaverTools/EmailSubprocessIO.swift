// Rune Weaver Tools — Shared blocking-IO helper single-sourcing subprocess execution.

import Foundation
import os
import RuneWeaverCore

/// Runs blocking Python subprocess I/O off the async executor.
enum EmailSubprocessIO {
    final class PipeDrain: Sendable {
        private let data = OSAllocatedUnfairLock(initialState: Data())

        func set(_ value: Data) {
            data.withLock { $0 = value }
        }

        func get() -> Data {
            data.withLock { $0 }
        }
    }

    /// Runs blocking bridge subprocess I/O off the async executor.
    static func runBridgeIO(
        scriptSource: String,
        payload: Data,
        pythonExecutable: String?,
        serviceName: String
    ) async throws -> Data {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do {
                        try continuation.resume(returning: runBridgeBlocking(
                            scriptSource: scriptSource,
                            payload: payload,
                            pythonExecutable: pythonExecutable,
                            serviceName: serviceName
                        ))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            // Non-cancellable by design: in-flight helpers run to completion.
        }
    }

    /// Spawns the Python helper and reads its output synchronously.
    private struct ConfiguredProcess {
        let process: Process
        let executablePath: String
        let argvPreview: String
    }

    private static func makeProcess(scriptSource: String, pythonExecutable: String?) -> ConfiguredProcess {
        let process = Process()
        let executablePath: String
        let argvPreview: String
        if let pythonExecutable, !pythonExecutable.isEmpty {
            process.executableURL = URL(fileURLWithPath: pythonExecutable)
            process.arguments = ["-c", scriptSource]
            executablePath = pythonExecutable
            argvPreview = "-c"
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", "-c", scriptSource]
            executablePath = "/usr/bin/env"
            argvPreview = "python3 -c"
        }
        return ConfiguredProcess(process: process, executablePath: executablePath, argvPreview: argvPreview)
    }

    private static func evaluateOutput(
        process: Process,
        stdoutDrain: PipeDrain,
        stderrDrain: PipeDrain,
        startTime: Date,
        serviceName: String,
        pid: Int32
    ) throws -> Data {
        let latencyMs = Date().timeIntervalSince(startTime) * 1000
        let output = stdoutDrain.get()
        let stderr = stderrDrain.get()
        if process.terminationStatus != 0 {
            let detail = String(data: stderr, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            MailSessionEventLog.live.emit(
                event: "bridge.result",
                account: serviceName.lowercased(),
                pid: pid,
                fields: [
                    "ok": false,
                    "status": Int(process.terminationStatus),
                    "latencyMs": latencyMs,
                    "stdoutBytes": output.count,
                    "stderrBytes": stderr.count,
                    "error": detail ?? "Exited with status \(process.terminationStatus)"
                ]
            )
            if let detail, !detail.isEmpty {
                throw EmailIMAPError.bridgeFailed("\(serviceName) helper failed: \(detail)")
            }
            throw EmailIMAPError.bridgeFailed(
                "\(serviceName) helper exited with status \(process.terminationStatus)"
            )
        }
        MailSessionEventLog.live.emit(
            event: "bridge.result",
            account: serviceName.lowercased(),
            pid: pid,
            fields: [
                "ok": !output.isEmpty,
                "status": 0,
                "latencyMs": latencyMs,
                "stdoutBytes": output.count,
                "stderrBytes": stderr.count
            ]
        )
        if output.isEmpty {
            let detail = String(data: stderr, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if detail.isEmpty {
                throw EmailIMAPError.decodeFailed("\(serviceName) helper returned no output")
            }
            throw EmailIMAPError.bridgeFailed("\(serviceName) helper failed: \(detail)")
        }
        return output
    }

    /// Spawns the Python helper and reads its output synchronously.
    private static func runBridgeBlocking(
        scriptSource: String,
        payload: Data,
        pythonExecutable: String?,
        serviceName: String
    ) throws -> Data {
        let startTime = Date()
        let configured = makeProcess(scriptSource: scriptSource, pythonExecutable: pythonExecutable)
        let process = configured.process
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        do {
            try process.run()
        } catch {
            MailSessionEventLog.live.emit(
                event: "session.spawn.error",
                account: serviceName.lowercased(),
                pid: nil,
                fields: ["executable": configured.executablePath, "error": error.localizedDescription]
            )
            throw EmailIMAPError.pythonUnavailable(
                "Could not launch python3 for \(serviceName) access: \(error.localizedDescription)"
            )
        }
        let pid = process.processIdentifier
        MailSessionEventLog.live.logSpawn(
            account: serviceName.lowercased(),
            pid: pid,
            executable: configured.executablePath,
            argvCount: (process.arguments?.count ?? 0) + 1,
            argvPreview: configured.argvPreview,
            scriptBytes: scriptSource.utf8.count
        )
        let stdoutDrain = PipeDrain()
        let stderrDrain = PipeDrain()
        let drainGroup = DispatchGroup()
        let outFD = outputPipe.fileHandleForReading.fileDescriptor
        let errFD = errorPipe.fileHandleForReading.fileDescriptor
        drainGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            let handle = FileHandle(fileDescriptor: outFD, closeOnDealloc: false)
            stdoutDrain.set(handle.readDataToEndOfFile())
            drainGroup.leave()
        }
        drainGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            let handle = FileHandle(fileDescriptor: errFD, closeOnDealloc: false)
            stderrDrain.set(handle.readDataToEndOfFile())
            drainGroup.leave()
        }
        do {
            try inputPipe.fileHandleForWriting.write(contentsOf: payload)
        } catch {
            process.terminate()
            drainGroup.wait()
            MailSessionEventLog.live.emit(
                event: "bridge.write.error",
                account: serviceName.lowercased(),
                pid: pid,
                fields: ["error": error.localizedDescription]
            )
            throw EmailIMAPError.bridgeFailed("Could not write \(serviceName) request: \(error.localizedDescription)")
        }
        try? inputPipe.fileHandleForWriting.close()
        process.waitUntilExit()
        drainGroup.wait()
        return try evaluateOutput(
            process: process,
            stdoutDrain: stdoutDrain,
            stderrDrain: stderrDrain,
            startTime: startTime,
            serviceName: serviceName,
            pid: pid
        )
    }
}

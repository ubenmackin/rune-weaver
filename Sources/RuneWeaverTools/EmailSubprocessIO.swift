// Rune Weaver Tools — Shared blocking-IO helper single-sourcing subprocess execution.
//
// Single-sources the background-queue spawn, pipe-drain, and wait path so
// IMAP and SMTP gateways share one cooperative-pool-safe execution model.
// Observes cancellation cooperatively and resumes exactly once, keeping
// torn writes off the pipes.

import Foundation
import os
import RuneWeaverCore

/// Runs blocking Python subprocess I/O off the async executor.
///
/// Suspends the caller until the spawn, stdin write, wait, and pipe
/// reads complete on a background queue, keeping blocking
/// `Process.waitUntilExit()` and `readDataToEndOfFile()` off the
/// cooperative pool. Shared by both `SubprocessIMAPGateway` and
/// `SubprocessSMTPGateway` so blocking subprocess execution stays
/// single-sourced.
///
/// Cancellation is observed cooperatively: already-cancelled tasks throw
/// before dispatch, and in-flight helpers run to completion so the
/// pipes never observe a torn write. The continuation resumes exactly
/// once on the single background completion path.
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
    /// - Parameters:
    ///   - scriptSource: Python script source to execute via `-c`.
    ///   - payload: Encoded bridge request (holds the password in memory only).
    ///   - pythonExecutable: Explicit `python3` path, or nil for `/usr/bin/env`.
    ///   - serviceName: Service label (e.g. "IMAP" or "SMTP") for error messages.
    /// - Returns: Raw stdout bytes.
    /// - Throws: Whatever the blocking helper throws, or `CancellationError` when already cancelled.
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
    ///
    /// Blocking helper for `runBridgeIO`. Must run on a background queue,
    /// never on the async executor: it calls blocking `Process.waitUntilExit()`
    /// and `readDataToEndOfFile()`. Stdout and stderr drain on background
    /// queues started before `waitUntilExit` so large payloads cannot
    /// deadlock with the Python writer.
    /// - Parameters:
    ///   - scriptSource: Python script source to execute via `-c`.
    ///   - payload: Encoded bridge request (holds the password in memory only).
    ///   - pythonExecutable: Explicit `python3` path, or nil for `/usr/bin/env`.
    ///   - serviceName: Service label (e.g. "IMAP" or "SMTP") for error messages.
    /// - Returns: Raw stdout bytes.
    /// - Throws: `EmailIMAPError` without any secret value.
    private static func runBridgeBlocking(
        scriptSource: String,
        payload: Data,
        pythonExecutable: String?,
        serviceName: String
    ) throws -> Data {
        let process = Process()
        if let pythonExecutable, !pythonExecutable.isEmpty {
            process.executableURL = URL(fileURLWithPath: pythonExecutable)
            process.arguments = ["-c", scriptSource]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", "-c", scriptSource]
        }
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        do {
            try process.run()
        } catch {
            throw EmailIMAPError.pythonUnavailable(
                "Could not launch python3 for \(serviceName) access: \(error.localizedDescription)"
            )
        }
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
            throw EmailIMAPError.bridgeFailed("Could not write \(serviceName) request: \(error.localizedDescription)")
        }
        try? inputPipe.fileHandleForWriting.close()
        process.waitUntilExit()
        drainGroup.wait()
        let output = stdoutDrain.get()
        let stderr = stderrDrain.get()
        if process.terminationStatus != 0 {
            let detail = String(data: stderr, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let detail, !detail.isEmpty {
                throw EmailIMAPError.bridgeFailed("\(serviceName) helper failed: \(detail)")
            }
            throw EmailIMAPError.bridgeFailed(
                "\(serviceName) helper exited with status \(process.terminationStatus)"
            )
        }
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
}

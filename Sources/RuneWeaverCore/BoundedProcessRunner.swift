// Rune Weaver Core — Shared bounded subprocess runner with timeout and cancellation.

import Dispatch
import Foundation
import os

/// Result of one bounded child-process invocation.
public struct BoundedProcessResult: Sendable, Equatable {
    /// Process exit status.
    public let exitCode: Int32
    /// Bounded stdout bytes retained up to the cap.
    public let stdout: Data
    /// Bounded stderr bytes retained up to the diagnostic cap.
    public let stderr: Data

    /// Creates a result.
    public init(exitCode: Int32, stdout: Data, stderr: Data) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }

    /// Stdout decoded lossily for diagnostics.
    public var stdoutString: String {
        String(data: stdout, encoding: .utf8) ?? ""
    }

    /// Stderr decoded lossily for diagnostics.
    public var stderrString: String {
        String(data: stderr, encoding: .utf8) ?? ""
    }
}

/// Errors from the shared bounded runner.
public enum BoundedProcessError: Error, Sendable, Equatable {
    /// The child did not exit before the timeout and was terminated.
    case timedOut(String)
    /// The child produced more than the output cap and was terminated.
    case outputLimitExceeded(String)
    /// The child could not be launched.
    case launchFailed(String)
}

extension BoundedProcessError: LocalizedError {
    /// Human-readable message without child output bytes.
    public var errorDescription: String? {
        switch self {
        case let .timedOut(detail): detail
        case let .outputLimitExceeded(detail): detail
        case let .launchFailed(detail): detail
        }
    }
}

/// Shared bounded subprocess execution.
public enum BoundedProcessRunner: Sendable {
    /// Default per-invocation timeout mirroring the container budget.
    public static let defaultTimeoutSeconds: TimeInterval = 30
    /// Default stdout cap bounding archive listings and helper payloads.
    public static let defaultMaxOutputBytes = 11 * 1024 * 1024
    /// Default stderr cap keeping diagnostics bounded.
    public static let defaultMaxErrorBytes = 64 * 1024

    /// Outcome of one incremental capped pipe read.
    struct CappedRead: Sendable {
        /// Bytes retained up to the cap.
        var data = Data()
        /// Whether the child produced more than the cap.
        var didExceed = false
    }

    /// Box holding the live child so cancellation can terminate it.
    public final class ProcessBox: Sendable {
        private let state = OSAllocatedUnfairLock(initialState: ProcessBoxState())

        /// Creates an empty box.
        public init() {}

        /// Publishes the spawned child.
        public func set(_ process: Process) {
            state.withLock { $0.process = process }
        }

        /// Terminates the child when still running.
        public func terminateIfRunning() {
            let process = state.withLock { $0.process }
            if let process, process.isRunning {
                process.terminate()
            }
        }
    }

    /// Lock state for `ProcessBox`, kept beside the box (not nested in it)
    /// so type nesting stays within the one-level budget.
    private struct ProcessBoxState: Sendable {
        /// Live child, if spawned and not yet reaped.
        var process: Process?
    }

    /// Runs one child synchronously with a timeout and bounded drains.
    public static func runSync(
        executableURL: URL,
        arguments: [String],
        inputData: Data? = nil,
        timeoutSeconds: TimeInterval = defaultTimeoutSeconds,
        maxOutputBytes: Int = defaultMaxOutputBytes,
        maxErrorBytes: Int = defaultMaxErrorBytes,
        processBox: ProcessBox? = nil
    ) throws -> BoundedProcessResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        processBox?.set(process)
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let stdinPipe = Pipe()
        process.standardInput = stdinPipe
        do {
            try process.run()
        } catch {
            throw BoundedProcessError.launchFailed("Could not launch \(executableURL.path): \(error.localizedDescription)")
        }
        if let inputData, !inputData.isEmpty {
            do {
                try stdinPipe.fileHandleForWriting.write(contentsOf: inputData)
            } catch {
                RuneWeaverLog.tools.debug("BoundedProcessRunner: Child closed stdin before write completed: \(error.localizedDescription)")
            }
        }
        try? stdinPipe.fileHandleForWriting.close()
        let group = DispatchGroup()
        let stdoutStore = OSAllocatedUnfairLock(initialState: CappedRead())
        let stderrStore = OSAllocatedUnfairLock(initialState: CappedRead())
        let outHandle = stdoutPipe.fileHandleForReading
        let errHandle = stderrPipe.fileHandleForReading
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = cappedRead(handle: outHandle, limit: max(1, maxOutputBytes), process: process)
            stdoutStore.withLock { $0 = result }
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = cappedRead(handle: errHandle, limit: max(1, maxErrorBytes), process: process)
            stderrStore.withLock { $0 = result }
            group.leave()
        }
        let timedOut = OSAllocatedUnfairLock(initialState: false)
        let timeoutWork = DispatchWorkItem {
            guard process.isRunning else { return }
            timedOut.withLock { $0 = true }
            process.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + max(0.1, timeoutSeconds), execute: timeoutWork)
        process.waitUntilExit()
        group.wait()
        timeoutWork.cancel()
        if timedOut.withLock({ $0 }) {
            throw BoundedProcessError.timedOut("Process timed out after \(Int(timeoutSeconds))s and was terminated.")
        }
        let outResult = stdoutStore.withLock { $0 }
        if outResult.didExceed {
            throw BoundedProcessError.outputLimitExceeded(
                "Process output exceeded the \(maxOutputBytes)-byte limit and was terminated."
            )
        }
        let errResult = stderrStore.withLock { $0 }
        return BoundedProcessResult(
            exitCode: process.terminationStatus,
            stdout: outResult.data,
            stderr: errResult.data
        )
    }

    /// Runs one child without blocking the cooperative pool.
    public static func runAsync(
        executableURL: URL,
        arguments: [String],
        inputData: Data? = nil,
        timeoutSeconds: TimeInterval = defaultTimeoutSeconds,
        maxOutputBytes: Int = defaultMaxOutputBytes,
        maxErrorBytes: Int = defaultMaxErrorBytes
    ) async throws -> BoundedProcessResult {
        try Task.checkCancellation()
        let box = ProcessBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do {
                        // Cancellation after this check still terminates via the box handler below
                        // instead of hanging the budget. The live child publishes to the same box
                        // so the handler kills the real process, not a placeholder.
                        if Task.isCancelled {
                            continuation.resume(throwing: CancellationError())
                            return
                        }
                        let result = try runSync(
                            executableURL: executableURL,
                            arguments: arguments,
                            inputData: inputData,
                            timeoutSeconds: timeoutSeconds,
                            maxOutputBytes: maxOutputBytes,
                            maxErrorBytes: maxErrorBytes,
                            processBox: box
                        )
                        continuation.resume(returning: result)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            box.terminateIfRunning()
        }
    }

    /// Reads one pipe in small chunks, terminating the child past the cap.
    static func cappedRead(handle: FileHandle, limit: Int, process: Process) -> CappedRead {
        var result = CappedRead()
        while true {
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: 16384)
            } catch {
                break
            }
            guard let chunk, !chunk.isEmpty else { break }
            result.data.append(chunk)
            if result.data.count > limit {
                if process.isRunning {
                    process.terminate()
                }
                result.didExceed = true
                break
            }
        }
        return result
    }
}

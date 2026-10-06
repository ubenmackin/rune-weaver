// Rune Weaver Core — Shared bounded subprocess runner with timeout and cancellation.

import Foundation
import os
#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

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

    /// Spawn environment without ssh-agent forwarding.
    ///
    /// No untrusted tier forwards the agent: the container CLI only forwards
    /// when explicitly passed `--ssh`, which isolated and detonation paths
    /// never pass, and stripping the socket keys here keeps an inherited
    /// `SSH_AUTH_SOCK` from reaching any child even when the parent shell
    /// carries one.
    /// - Returns: Parent environment minus agent socket keys.
    static func sanitizedSpawnEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "SSH_AUTH_SOCK")
        env.removeValue(forKey: "SSH_AGENT_PID")
        return env
    }

    /// Outcome of one incremental capped pipe read.
    struct CappedRead: Sendable {
        /// Bytes retained up to the cap.
        var data = Data()
        /// Whether the child produced more than the cap.
        var didExceed = false
    }

    /// Box holding the live child so cancellation can terminate it.
    /// Single-use per invocation: `cancelled` latches once set so a reused box
    /// would immediately terminate the next child published via `set`. Create a
    /// fresh box for every run (`runAsync` does so internally); never reuse a
    /// box across invocations.
    public final class ProcessBox: Sendable {
        private let state = OSAllocatedUnfairLock(initialState: ProcessBoxState())

        /// Creates an empty box.
        public init() {}

        /// Publishes the spawned child, terminating it at once when the box
        /// already latched cancellation (which is why boxes stay single-use).
        public func set(_ process: Process) {
            // Capture the identifier on the spawning executor so only the pid
            // crosses executors; the non-Sendable child itself never leaves
            // the spawner, avoiding any cross-executor use of its handlers.
            let pid = process.processIdentifier
            let cancelled = state.withLock { state -> Bool in
                state.pid = pid
                return state.cancelled
            }
            if cancelled {
                Self.signalTermination(pid: pid)
            }
        }

        /// Terminates the child when still running and latches cancellation so a
        /// later `set` on the same box cannot outlive the cancel.
        public func terminateIfRunning() {
            let pid = state.withLock { state -> Int32? in
                state.cancelled = true
                return state.pid
            }
            if let pid {
                Self.signalTermination(pid: pid)
            }
        }

        /// Best-effort SIGTERM matching `Process.terminate` without touching the
        /// child off the spawning executor. A stale pid after exit reports
        /// `ESRCH` and is ignored; the single-use bounded lifetime keeps pid
        /// reuse outside the termination window.
        private static func signalTermination(pid: Int32) {
            guard pid > 0 else { return }
            _ = kill(pid, SIGTERM)
            _ = kill(-pid, SIGTERM)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
                if kill(pid, 0) == 0 {
                    _ = kill(pid, SIGKILL)
                    _ = kill(-pid, SIGKILL)
                }
            }
        }
    }

    /// Lock state for `ProcessBox`, kept beside the box (not nested in it)
    /// so type nesting stays within the one-level budget.
    /// Isolation: only the Sendable process identifier crosses executors via the
    /// lock. The live `Process` stays on the spawning executor for
    /// `terminationHandler`, drains, and `waitUntilExit`; cancellation and
    /// timeouts signal by pid so no non-Sendable state is shared.
    private struct ProcessBoxState: Sendable {
        /// Identifier of the spawned child, if published yet.
        var pid: Int32?
        /// True if cancellation was requested before the child spawned.
        var cancelled = false
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
        process.environment = sanitizedSpawnEnvironment()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let stdinPipe = Pipe()
        process.standardInput = stdinPipe
        do {
            try process.run()
            // Publish only after a successful spawn so a launch failure never
            // leaves a dead process in the box for cancellation to chase.
            processBox?.set(process)
        } catch {
            throw BoundedProcessError.launchFailed("Could not launch \(executableURL.path): \(error.localizedDescription)")
        }
        writeStandardInput(pipe: stdinPipe, data: inputData)
        return try drainAndCollect(
            process: process,
            stdoutPipe: stdoutPipe,
            stderrPipe: stderrPipe,
            timeoutSeconds: timeoutSeconds,
            maxOutputBytes: maxOutputBytes,
            maxErrorBytes: maxErrorBytes
        )
    }

    /// Writes standard input to the child process asynchronously and closes the pipe.
    private static func writeStandardInput(pipe: Pipe, data: Data?) {
        if let data, !data.isEmpty {
            DispatchQueue.global(qos: .userInitiated).async {
                defer {
                    try? pipe.fileHandleForWriting.close()
                }
                do {
                    try pipe.fileHandleForWriting.write(contentsOf: data)
                } catch {
                    RuneWeaverLog.tools.debug("BoundedProcessRunner: Child closed stdin before write completed: \(error.localizedDescription)")
                }
            }
        } else {
            try? pipe.fileHandleForWriting.close()
        }
    }

    /// Terminates a running process with SIGTERM and schedules SIGKILL escalation after 500ms.
    private static func terminateWithEscalation(_ process: Process) {
        process.terminate()
        let pid = process.processIdentifier
        guard pid > 0 else { return }
        _ = kill(-pid, SIGTERM)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
            if kill(pid, 0) == 0 {
                _ = kill(pid, SIGKILL)
                _ = kill(-pid, SIGKILL)
            }
        }
    }

    /// Forcibly kills a running process with SIGKILL immediately.
    private static func forceKillProcess(_ process: Process) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        guard pid > 0 else { return }
        _ = kill(pid, SIGKILL)
        _ = kill(-pid, SIGKILL)
    }

    /// Drains stdout and stderr pipes in a single-threaded poll loop with timeout and limits.
    private static func drainAndCollect(
        process: Process,
        stdoutPipe: Pipe,
        stderrPipe: Pipe,
        timeoutSeconds: TimeInterval,
        maxOutputBytes: Int,
        maxErrorBytes: Int
    ) throws -> BoundedProcessResult {
        // Single-threaded readiness loop replaces the prior concurrent drains
        // plus dispatch timeout: one thread polls both pipes, enforces caps,
        // and watches the deadline so no non-Sendable child state crosses
        // executors and no raw GCD owns the process lifetime.
        let outFD = stdoutPipe.fileHandleForReading.fileDescriptor
        let errFD = stderrPipe.fileHandleForReading.fileDescriptor
        setNonBlocking(outFD)
        setNonBlocking(errFD)
        let stdoutLimit = max(1, maxOutputBytes)
        let stderrLimit = max(1, maxErrorBytes)
        let deadline = Date().addingTimeInterval(max(0.1, timeoutSeconds))
        var outData = Data()
        var errData = Data()
        var outDone = false
        var errDone = false
        var outExceeded = false
        var errExceeded = false
        var timedOut = false
        while true {
            let outFinished = outDone || outExceeded
            let errFinished = errDone || errExceeded
            if outFinished, errFinished, !process.isRunning {
                break
            }
            // Deadline check precedes reads so a hung child is terminated even
            // with no output; the latched flag preserves timeout over later caps.
            if !timedOut, Date() >= deadline {
                if process.isRunning {
                    timedOut = true
                    terminateWithEscalation(process)
                }
            }
            var fds = [
                pollfd(fd: outFinished ? -1 : outFD, events: Int16(POLLIN), revents: 0),
                pollfd(fd: errFinished ? -1 : errFD, events: Int16(POLLIN), revents: 0)
            ]
            // Short poll acts as the timeout tick when idle; zero wait once the
            // child has exited so remaining pipe bytes drain without delay.
            let pollTimeout: Int32 = process.isRunning ? 50 : 0
            let ready: Int32 = fds.withUnsafeMutableBufferPointer { buffer -> Int32 in
                guard let base = buffer.baseAddress else { return 0 }
                return poll(base, nfds_t(buffer.count), pollTimeout)
            }
            if ready < 0, errno == EINTR {
                continue
            }
            let outReady = !outFinished && (isPollReadable(fds[0].revents) || !process.isRunning)
            let errReady = !errFinished && (isPollReadable(fds[1].revents) || !process.isRunning)
            if outReady {
                drainNonBlocking(fd: outFD, into: &outData, eof: &outDone, exceeded: &outExceeded, limit: stdoutLimit, process: process)
            }
            if errReady {
                drainNonBlocking(fd: errFD, into: &errData, eof: &errDone, exceeded: &errExceeded, limit: stderrLimit, process: process)
            }
            // Both pipes finished but the child lingers (closed stdio yet still
            // running): keep ticking the deadline above instead of spinning.
            if outFinished, errFinished, process.isRunning {
                continue
            }
            if outDone, errDone, !process.isRunning {
                break
            }
        }
        forceKillProcess(process)
        process.waitUntilExit()
        // Timeout wins over caps, matching the prior dispatch ordering where
        // the timeout flag was checked before the output-cap flag.
        if timedOut {
            throw BoundedProcessError.timedOut("Process timed out after \(Int(timeoutSeconds))s and was terminated.")
        }
        if outExceeded {
            throw BoundedProcessError.outputLimitExceeded(
                "Process output exceeded the \(maxOutputBytes)-byte limit and was terminated."
            )
        }
        // Stderr caps truncate diagnostics without failing, preserving the
        // prior drain where only stdout excess threw.
        return BoundedProcessResult(
            exitCode: process.terminationStatus,
            stdout: outData,
            stderr: errData
        )
    }
}

// MARK: - Async Runner

extension BoundedProcessRunner {
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
        let limits = ProcessDrainLimits(stdout: max(1, maxOutputBytes), stderr: max(1, maxErrorBytes))
        let clampedTimeout = max(0.1, timeoutSeconds)
        let budgets = ProcessBudgets(timeoutSeconds: timeoutSeconds, maxOutputBytes: maxOutputBytes)
        // Sendable buffers isolate pipe bytes off the spawning executor so the
        // readability handlers stay @Sendable under strict concurrency.
        let buffers = CappedPipeBuffers()
        let timedOut = OSAllocatedUnfairLock(initialState: false)
        let timeoutTaskStore = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = sanitizedSpawnEnvironment()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let stdinPipe = Pipe()
        process.standardInput = stdinPipe
        attachAsyncDrains(
            stdoutPipe: stdoutPipe,
            stderrPipe: stderrPipe,
            buffers: buffers,
            limits: limits,
            box: box
        )
        do {
            let result = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<BoundedProcessResult, Error>) in
                    // Termination is the single resumer; the timeout only sets
                    // the flag and terminates so timeout versus cancel stays
                    // distinguishable via the flag plus Task.isCancelled after.
                    let gate = CheckedOnce<BoundedProcessResult>(continuation)
                    process.terminationHandler = { proc in
                        stdoutPipe.fileHandleForReading.readabilityHandler = nil
                        stderrPipe.fileHandleForReading.readabilityHandler = nil
                        let timeoutTask = timeoutTaskStore.withLock { $0 }
                        if let timeoutTask {
                            timeoutTask.cancel()
                        }
                        drainBoundedTail(
                            stdoutPipe: stdoutPipe,
                            stderrPipe: stderrPipe,
                            buffers: buffers,
                            limits: limits
                        )
                        do {
                            let terminal = try mapBoundedTermination(
                                status: proc.terminationStatus,
                                buffers: buffers,
                                didTimeOut: timedOut.withLock { $0 },
                                budgets: budgets
                            )
                            gate.resume(returning: terminal)
                        } catch {
                            gate.resume(throwing: error)
                        }
                    }
                    do {
                        try process.run()
                        // Publish only after a successful spawn so a launch
                        // failure never leaves a dead child for cancel to chase.
                        // Cancellation racing the spawn still terminates via the
                        // latched box instead of leaking until the budget fires.
                        box.set(process)
                    } catch {
                        stdoutPipe.fileHandleForReading.readabilityHandler = nil
                        stderrPipe.fileHandleForReading.readabilityHandler = nil
                        gate.resume(throwing: BoundedProcessError.launchFailed("Could not launch \(executableURL.path): \(error.localizedDescription)"))
                        return
                    }
                    writeBoundedInput(stdinPipe: stdinPipe, inputData: inputData)
                    let timeoutTask = startBoundedTimeout(
                        clampedTimeout: clampedTimeout,
                        timedOut: timedOut,
                        box: box
                    )
                    timeoutTaskStore.withLock { $0 = timeoutTask }
                    // The child may have exited before the timeout stored;
                    // the handler already cancelled nil, so cancel the stray
                    // sleeper now instead of leaving it ticking past settle.
                    if !process.isRunning {
                        timeoutTask.cancel()
                    }
                }
            } onCancel: {
                box.terminateIfRunning()
            }
            // A cancelled turn terminates the child, which resumes non-zero;
            // report cancel as cancellation so callers distinguish abort from
            // timeout or cap failure.
            try Task.checkCancellation()
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // A timeout or cap racing a cancel still reports cancellation so a
            // user abort is never mistaken for a budget failure.
            if Task.isCancelled {
                throw CancellationError()
            }
            throw error
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

    /// Marks a descriptor non-blocking so the sync readiness loop never parks
    /// on one pipe while the other fills.
    private static func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL)
        if flags != -1 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }
    }

    /// Drains one non-blocking descriptor until it would block, EOF, or the cap.
    /// Past-cap data terminates the child and latches `exceeded` without
    /// throwing here so the caller preserves timeout-over-cap ordering.
    private static func drainNonBlocking(
        fd: Int32,
        into data: inout Data,
        eof: inout Bool,
        exceeded: inout Bool,
        limit: Int,
        process: Process
    ) {
        var chunk = [UInt8](repeating: 0, count: 16384)
        while true {
            let bytesRead: Int = chunk.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return read(fd, base, raw.count)
            }
            if bytesRead > 0 {
                data.append(contentsOf: chunk.prefix(bytesRead))
                if data.count > limit {
                    if process.isRunning {
                        process.terminate()
                        let pid = process.processIdentifier
                        if pid > 0 {
                            _ = kill(-pid, SIGTERM)
                            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
                                if kill(pid, 0) == 0 {
                                    _ = kill(pid, SIGKILL)
                                    _ = kill(-pid, SIGKILL)
                                }
                            }
                        }
                    }
                    exceeded = true
                    return
                }
                // Loop again: more bytes may already be queued without another poll.
                continue
            }
            if bytesRead == 0 {
                eof = true
                return
            }
            if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                return
            }
            eof = true
            return
        }
    }

    /// Reports whether poll revents carry readable bytes or a hangup/error that
    /// warrants one final non-blocking read to reach EOF.
    private static func isPollReadable(_ revents: Int16) -> Bool {
        let mask = revents
        return (mask & Int16(POLLIN) != 0)
            || (mask & Int16(POLLHUP) != 0)
            || (mask & Int16(POLLERR) != 0)
            || (mask & Int16(POLLNVAL) != 0)
    }
}

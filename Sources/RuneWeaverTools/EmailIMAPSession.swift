// Rune Weaver Tools — Persistent read-only IMAP session actor with framing, timeouts, and once-reconnect.
//
// Purpose: keeps one IMAP connection open across status, search, and fetch turns so
// repeated reads avoid redialing. Scope: read-only newline-delimited JSON framing
// over a piped python3 helper, with per-command budgets and a single reconnect.
// Architectural role: session lifecycle owner; line framing rides the transport
// seam so live Process pipes and hermetic fakes share one contract. Every read
// stays peek-only and every response reuses the one-shot envelope shape.

import Foundation
import os
import RuneWeaverCore
#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// Line framing seam for the persistent IMAP session.
///
/// The actor writes one JSON document per line and consumes exactly one response
/// line per command. Live Process pipes and hermetic fakes share this contract
/// so framing, timeout, and reconnect behavior stays testable without dialing.
public protocol SessionLineTransport: Sendable {
    /// Helper child pid when known, nil for hermetic fakes.
    ///
    /// The live pipe returns the spawned child pid so session events can tie
    /// log lines to the owning helper; fakes return nil so hermetic runs stay
    /// pid-free while still emitting the shared envelope.
    var processIdentifier: Int32? { get }
    /// Newest retained helper stderr for failure dumps.
    ///
    /// The live drain keeps up to 8KB for `session.stderr` dumps while the
    /// 500-char timeout tail stays separate; fakes mirror the seam with canned
    /// text so dump coverage stays hermetic.
    var retainedStderr: String { get }
    /// Writes one JSON document line to the session helper.
    /// - Parameter line: Single JSON document without a trailing newline.
    func writeLine(_ line: String) async throws
    /// Reads one response line with a bounded wait.
    /// - Parameter timeout: Seconds to wait before reporting a timeout.
    /// - Returns: Single response line without the trailing newline.
    func readLine(timeout: TimeInterval) async throws -> String
    /// Terminates the underlying helper regardless of current state.
    func terminate() async
}

/// Exactly-once resume coordinator for one cancellable session line read.
///
/// The blocking pipe reader, timeout timer, and task cancellation race; only
/// the first finisher resumes the continuation while losers exit silently once
/// teardown unblocks the stray reader. A winner arriving before the
/// continuation publishes stores its result so a late publish still delivers
/// it instead of hanging the read.
///
/// Implemented as an actor to provide safe, race-free synchronization over the
/// continuation and timeout task without manual locks or unchecked Sendability.
private actor SessionLineReadCoordinator {
    /// Published continuation awaiting the winning racer.
    private var continuation: CheckedContinuation<String, Error>?
    /// Whether `set` already published the continuation.
    private var published = false
    /// Whether a racer already settled the verdict.
    private var settled = false
    /// Winning result stored for a late publish when cancellation wins first.
    private var stored: Result<String, Error>?
    /// Pending timeout task cancelled once any racer wins.
    private var timerTask: Task<Void, Never>?

    /// Publishes the continuation, delivering an early winning result when present.
    /// - Parameter continuation: Continuation awaiting the read verdict.
    func set(_ continuation: CheckedContinuation<String, Error>) {
        guard !published else { return }
        published = true
        if settled, let stored {
            continuation.resume(with: stored)
        } else {
            self.continuation = continuation
        }
    }

    /// Records the timeout task so a winning reader or cancellation can drop it.
    /// - Parameter task: Scheduled timeout task.
    func setTimerTask(_ task: Task<Void, Never>) {
        if settled {
            task.cancel()
        } else {
            timerTask = task
        }
    }

    /// Attempts to settle the read with success.
    /// - Parameter value: Line won by this racer.
    /// - Returns: True when this caller won, false for late losers.
    @discardableResult
    func resume(returning value: String) -> Bool {
        resume(with: .success(value))
    }

    /// Attempts to settle the read with failure.
    /// - Parameter error: Error won by this racer.
    /// - Returns: True when this caller won, false for late losers.
    @discardableResult
    func resume(throwing error: Error) -> Bool {
        resume(with: .failure(error))
    }

    /// Settles the read unless already settled, cancelling the pending timer task.
    /// - Parameter result: Winning verdict.
    /// - Returns: True when this caller won, false for late losers.
    @discardableResult
    func resume(with result: Result<String, Error>) -> Bool {
        guard !settled else { return false }
        settled = true
        stored = result
        timerTask?.cancel()
        timerTask = nil
        let held = continuation
        continuation = nil
        if let held {
            held.resume(with: result)
        }
        return true
    }
}

/// Shared timeout wording for session line transports.
///
/// Both the live Process pipe and the hermetic fake report timeouts with one
/// identical transport-phrased message so timeout and reconnect tests assert
/// the exact copy without drift between the live and hermetic paths. A
/// non-empty helper stderr tail rides after a separator so a silent helper
/// still leaves its dying words; empty stderr keeps the base copy unchanged.
public enum SessionLineTimeout {
    /// Builds the transport-phrased timeout message for a read budget.
    /// - Parameter timeout: Seconds waited before reporting the timeout.
    /// - Returns: Timeout detail shared by live and fake transports.
    public static func timeoutMessage(timeout: TimeInterval) -> String {
        timeoutMessage(timeout: timeout, stderrTail: nil)
    }

    /// Builds the transport-phrased timeout message with an optional stderr tail.
    ///
    /// The tail carries only helper diagnostics; the session script contract
    /// keeps secrets out of stderr, and the 500-char cap bounds the detail
    /// even if that contract ever changes. An empty tail keeps the base copy
    /// so existing assertions without diagnostics stay exact.
    /// - Parameters:
    ///   - timeout: Seconds waited before reporting the timeout.
    ///   - stderrTail: Retained helper stderr, or nil/empty for the base copy.
    /// - Returns: Base timeout detail, plus the truncated tail after a separator when present.
    public static func timeoutMessage(timeout: TimeInterval, stderrTail: String?) -> String {
        let base = "IMAP session command timed out after \(String(format: "%g", timeout))s"
        let trimmed = (stderrTail ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return base }
        let cap = ProcessSessionLineTransport.maxStderrTailChars
        let tail = trimmed.count > cap ? String(trimmed.suffix(cap)) : trimmed
        return base + " | stderr: " + tail
    }
}

/// Retained tail of helper stderr for timeout diagnostics.
///
/// The live drain appends incrementally and keeps only the newest bytes so a
/// hung helper's last words survive without unbounded growth. Decoding is
/// lossy-tolerant so a byte-boundary split never drops the whole tail.
private final class SessionStderrTail: Sendable {
    private struct State: Sendable {
        var data = Data()
        let cap: Int
    }

    /// Guards retained bytes.
    private let state: OSAllocatedUnfairLock<State>

    /// Creates a tail store with a byte cap.
    /// - Parameter cap: Maximum bytes retained.
    init(cap: Int) {
        self.state = OSAllocatedUnfairLock(initialState: State(data: Data(), cap: cap))
    }

    /// Appends a chunk, keeping only the newest capped bytes.
    /// - Parameter chunk: Fresh stderr bytes from the drain.
    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        state.withLock { tail in
            tail.data.append(chunk)
            if tail.data.count > tail.cap {
                tail.data.removeSubrange(0 ..< (tail.data.count - tail.cap))
            }
        }
    }

    /// Returns the retained tail as trimmed text.
    /// - Returns: Trimmed stderr text, or empty when nothing was captured.
    func snapshot() -> String {
        state.withLock { tail in
            String(decoding: tail.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

/// Live Process-pipe line transport for the persistent session helper.
///
/// Spawns `python3 -u -c` with piped stdin and stdout so each command is one
/// unbuffered JSON line each way. Standard error drains in the background so
/// helper diagnostics never block a read. All secrets stay in the written line;
/// nothing here logs connection fields. Named owner for stderr retention: this
/// transport keeps the last 500 stderr bytes for timeout errors plus the full
/// 8KB dump for failure events so a stalled helper still leaves its dying words.
///
/// Sendable proof: All mutable state is isolated behind `ioState` and `pending`
/// using `OSAllocatedUnfairLock`. The child process is reaped off-pool by pid
/// via POSIX `waitpid` without capturing non-Sendable references.
public final class ProcessSessionLineTransport: SessionLineTransport, Sendable {
    /// Maximum stderr characters retained for timeout diagnostics.
    ///
    /// Keeps timeout errors readable while preserving the helper's last words;
    /// the session script contract keeps secrets out of stderr, and this bound
    /// holds even if that contract ever changes.
    public static let maxStderrTailChars = 500
    /// Maximum stderr bytes retained for failure dumps.
    ///
    /// Single-sourced from `MailSessionEventLog.maxStderrDumpBytes` so the
    /// live drain bound and the log dump bound cannot drift; the 500-char
    /// timeout tail stays unchanged for readable timeout errors.
    public static let maxStderrDumpBytes = MailSessionEventLog.maxStderrDumpBytes

    /// Leading argv entries handed to exec without the trailing script body.
    ///
    /// Single source for spawn construction and spawn-event summaries so an
    /// interpreter-flag change cannot drift the log: the live initializer
    /// appends the script body to this prefix while session summaries derive
    /// counts plus previews from it. An explicit empty path collapses to the
    /// `PATH` lookup like the initializer.
    /// - Parameter pythonExecutable: Explicit interpreter path, or nil/empty for `python3` on `PATH`.
    /// - Returns: Leading flags without the script body.
    public static func argvLeading(pythonExecutable: String?) -> [String] {
        if let pythonExecutable, !pythonExecutable.isEmpty {
            return ["-u", "-c"]
        }
        return ["python3", "-u", "-c"]
    }

    /// Argv summary for the spawn event without the script body.
    ///
    /// Derives the count plus preview from `argvLeading` so construction and
    /// logging share one owner; the script body stays a byte size alone.
    /// - Parameters:
    ///   - pythonExecutable: Explicit interpreter path, or nil/empty for `python3` on `PATH`.
    ///   - scriptBytes: UTF-8 bytes of the script carried as the last arg.
    /// - Returns: Argv count plus leading-flag preview.
    public static func argvSummary(pythonExecutable: String?, scriptBytes _: Int) -> (count: Int, preview: String) {
        let leading = argvLeading(pythonExecutable: pythonExecutable)
        return (leading.count + 1, leading.joined(separator: " "))
    }

    /// Underlying helper process. Touched only while holding `ioState`.
    private let process: Process
    /// Writable stdin handle. Written and closed only while holding `ioState`.
    private let stdinHandle: FileHandle
    /// Readable stdout handle. Captured under `ioState`, read outside it.
    private let stdoutHandle: FileHandle
    /// Readable stderr handle. Drained off-pool; closed under `ioState`.
    private let stderrHandle: FileHandle
    /// Retained stderr tail feeding timeout errors. Appended only by the drain.
    private let stderrTail: SessionStderrTail
    /// Retained stderr dump feeding failure events. Appended only by the drain.
    private let stderrDump: SessionStderrTail
    /// Buffered stdout bytes awaiting a newline boundary.
    private let pending = OSAllocatedUnfairLock(initialState: Data())
    /// Termination and handle closure state.
    private struct IOState: Sendable {
        var didTerminate = false
    }

    /// Guards process, stdin/stdout/stderr handles, and termination state.
    private let ioState = OSAllocatedUnfairLock(initialState: IOState())

    /// Spawns the session helper with piped stdio.
    /// - Parameters:
    ///   - pythonExecutable: Explicit interpreter path, or nil for `python3` on `PATH`.
    ///   - scriptSource: Python source executed via `-u -c`.
    /// - Throws: `EmailIMAPError.pythonUnavailable` when the spawn fails.
    public init(pythonExecutable: String?, scriptSource: String) throws {
        let spawned = Process()
        let leading = Self.argvLeading(pythonExecutable: pythonExecutable)
        if let pythonExecutable, !pythonExecutable.isEmpty {
            spawned.executableURL = URL(fileURLWithPath: pythonExecutable)
        } else {
            spawned.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        }
        spawned.arguments = leading + [scriptSource]
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        spawned.standardInput = stdinPipe
        spawned.standardOutput = stdoutPipe
        spawned.standardError = stderrPipe
        let stderrReading = stderrPipe.fileHandleForReading
        let tailStore = SessionStderrTail(cap: Self.maxStderrTailChars)
        let dumpStore = SessionStderrTail(cap: Self.maxStderrDumpBytes)
        self.stderrTail = tailStore
        self.stderrDump = dumpStore
        // Drain diagnostics off-pool so stderr never blocks the helper while
        // retaining the last words for timeout errors plus the fuller dump for
        // failure events. Closing this handle in `terminate` (or on natural
        // exit) unblocks the drain, which is the cancellation mechanism for
        // this blocking read.
        DispatchQueue.global(qos: .utility).async {
            while true {
                let chunk: Data?
                do {
                    chunk = try stderrReading.read(upToCount: 4096)
                } catch {
                    break
                }
                guard let chunk, !chunk.isEmpty else { break }
                tailStore.append(chunk)
                dumpStore.append(chunk)
            }
        }
        self.process = spawned
        self.stdinHandle = stdinPipe.fileHandleForWriting
        self.stdoutHandle = stdoutPipe.fileHandleForReading
        self.stderrHandle = stderrReading
        // Reap the child without blocking the caller: the handler closes the
        // stderr drain handle under `ioState` after checking `didTerminate` so
        // it serializes against `terminate` instead of racing its guarded closes.
        self.process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.ioState.withLock { state in
                guard !state.didTerminate else { return }
                try? self.stderrHandle.close()
            }
        }
        do {
            try spawned.run()
        } catch {
            throw EmailIMAPError.pythonUnavailable(
                "Could not launch python3 for IMAP session access: \(error.localizedDescription)"
            )
        }
    }

    /// Writes one JSON line plus a newline to the helper stdin.
    ///
    /// The stdin write holds `ioState` so it serializes against `terminate`
    /// closes; a write racing teardown maps to a transport-phrased error.
    /// - Parameter line: Single JSON document without a trailing newline.
    public func writeLine(_ line: String) async throws {
        let payload = Data((line + "\n").utf8)
        do {
            try ioState.withLock { state in
                guard !state.didTerminate else {
                    throw EmailIMAPError.bridgeFailed("IMAP session closed")
                }
                try stdinHandle.write(contentsOf: payload)
            }
        } catch {
            throw EmailIMAPError.bridgeFailed("IMAP session write failed: \(error.localizedDescription)")
        }
    }

    /// Reads one stdout line, racing a blocking drain against the budget.
    ///
    /// The blocking drain runs off the cooperative pool so a hung helper never
    /// stalls the executor. The first finisher wins; a timeout surfaces with a
    /// transport-phrased message plus the retained stderr tail while the stray
    /// reader exits once teardown unblocks it. Cancellation abandons the
    /// reader, drops the timer, and resumes with `CancellationError` instead
    /// of waiting out the budget.
    /// - Parameter timeout: Seconds to wait before reporting a timeout.
    /// - Returns: Single response line without the trailing newline.
    public func readLine(timeout: TimeInterval) async throws -> String {
        let budget = max(0, timeout)
        try Task.checkCancellation()
        let coordinator = SessionLineReadCoordinator()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                Task {
                    await coordinator.set(continuation)
                }
                DispatchQueue.global(qos: .utility).async { [self] in
                    do {
                        let line = try self.blockingReadLine()
                        Task {
                            await coordinator.resume(returning: line)
                        }
                    } catch {
                        Task {
                            await coordinator.resume(throwing: error)
                        }
                    }
                }
                let timer = Task {
                    try? await Task.sleep(nanoseconds: UInt64(budget * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    let tail = self.stderrTail.snapshot()
                    await coordinator.resume(
                        throwing: EmailIMAPError.bridgeFailed(
                            SessionLineTimeout.timeoutMessage(timeout: timeout, stderrTail: tail)
                        )
                    )
                }
                Task {
                    await coordinator.setTimerTask(timer)
                }
                if Task.isCancelled {
                    Task {
                        await coordinator.resume(throwing: CancellationError())
                    }
                }
            }
        } onCancel: {
            Task {
                await coordinator.resume(throwing: CancellationError())
            }
        }
    }

    /// Terminates the helper and closes stdio exactly once, then reaps off-pool.
    ///
    /// Holds `ioState` across the termination flag, `terminate`, and all three
    /// handle closes so concurrent writers serialize instead of writing into a
    /// half-closed pipe. Closing stdout/stderr unblocks the stray blocking
    /// reader and the stderr drain; `waitpid` runs off the cooperative
    /// pool on GCD so teardown never stalls the executor or captures non-Sendable state.
    public func terminate() async {
        let shouldReap: Bool = ioState.withLock { state in
            guard !state.didTerminate else { return false }
            state.didTerminate = true
            process.terminate()
            try? stdinHandle.close()
            try? stdoutHandle.close()
            try? stderrHandle.close()
            return true
        }
        guard shouldReap else { return }
        let pid = process.processIdentifier
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            waitpid(pid, &status, 0)
        }
    }

    /// Spawned helper pid for session events.
    ///
    /// Read under `ioState` so it serializes against a concurrent `terminate`;
    /// the pid is stable once the spawn succeeds. Lets event lines tie diagnostics
    /// to the owning helper.
    public var processIdentifier: Int32? {
        ioState.withLock { _ in process.processIdentifier }
    }

    /// Newest retained helper stderr for failure dumps.
    ///
    /// Returns the full 8KB dump snapshot; timeout errors keep using the
    /// separate 500-char tail so the existing warning copy never grows.
    public var retainedStderr: String {
        stderrDump.snapshot()
    }

    /// Blocks the calling thread until one newline-terminated line arrives.
    ///
    /// The stdout handle is captured under `ioState` and read outside it so a
    /// hung helper never holds the lock while `terminate` waits to close. A
    /// close racing the read throws and maps to a transport-phrased closure
    /// error; buffered bytes stay under `pending`.
    /// - Returns: Single line without the trailing newline.
    private func blockingReadLine() throws -> String {
        while true {
            let buffered: Data? = pending.withLock { pendingData in
                guard let newline = pendingData.firstIndex(of: 10) else {
                    return nil
                }
                let slice = Data(pendingData.prefix(upTo: newline))
                pendingData.removeSubrange(pendingData.startIndex ... newline)
                return slice
            }
            if let buffered {
                guard let line = String(data: buffered, encoding: .utf8) else {
                    throw EmailIMAPError.decodeFailed("IMAP session returned non-UTF8 line")
                }
                return line
            }
            let stdoutReading: FileHandle = ioState.withLock { _ in stdoutHandle }
            let chunk: Data?
            do {
                chunk = try stdoutReading.read(upToCount: 4096)
            } catch {
                throw EmailIMAPError.bridgeFailed(
                    "IMAP session connection closed: \(error.localizedDescription)"
                )
            }
            guard let chunk, !chunk.isEmpty else {
                throw EmailIMAPError.bridgeFailed("IMAP session connection closed")
            }
            pending.withLock { pendingData in
                pendingData.append(chunk)
            }
        }
    }
}

/// In-memory line transport keeping session framing tests hermetic.
///
/// Records every written line and serves queued response lines in order. An
/// optional hang mode reports the same transport-phrased timeout as the live
/// pipe without waiting out the budget, so timeout and reconnect tests stay
/// fast while still asserting the exact copy and the requested budget. Canned
/// stderr mirrors the live retained tail through the same timeout helper, so
/// live-drain retention is covered through this seam without spawning helpers.
///
/// Sendable proof: All mutable state is bundled in Sendable `State` and protected
/// by `OSAllocatedUnfairLock`, providing verified compile-time Sendable conformance.
public final class FakeSessionLineTransport: SessionLineTransport, Sendable {
    private struct State: Sendable {
        var written: [String] = []
        var responses: [String]
        var hang: Bool
        var stderrText: String
        var pid: Int32?
        var terminated = false
        var terminates = 0
        var reads = 0
        var timeouts: [TimeInterval] = []
    }

    private let state: OSAllocatedUnfairLock<State>

    /// Every line written through `writeLine`, in order.
    public var writtenLines: [String] {
        state.withLock { $0.written }
    }

    /// Number of `writeLine` calls observed.
    public var writeCount: Int {
        state.withLock { $0.written.count }
    }

    /// Number of `readLine` calls observed.
    public var readCount: Int {
        state.withLock { $0.reads }
    }

    /// Number of `terminate` calls observed.
    public var terminateCount: Int {
        state.withLock { $0.terminates }
    }

    /// Whether `terminate` has run at least once.
    public var isTerminated: Bool {
        state.withLock { $0.terminated }
    }

    /// Requested read budgets in call order, for budget assertions.
    public var readTimeouts: [TimeInterval] {
        state.withLock { $0.timeouts }
    }

    /// Canned stderr tail surfaced on timeouts, mirroring the live drain.
    public var stderrText: String {
        state.withLock { $0.stderrText }
    }

    /// Hermetic pid for the seam, nil unless a test injects one.
    public var processIdentifier: Int32? {
        state.withLock { $0.pid }
    }

    /// Canned stderr dump for failure events, mirroring the live 8KB drain.
    public var retainedStderr: String {
        state.withLock { MailSessionEventLog.cappedDump($0.stderrText) }
    }

    /// Creates an in-memory transport with canned responses.
    /// - Parameters:
    ///   - responses: Response lines served first-in first-out, one per read.
    ///   - hangReads: When true, every read reports a timeout instead of serving the queue.
    ///   - stderrText: Canned stderr tail appended to timeout errors, mirroring the live drain.
    ///   - pid: Hermetic pid for spawn correlation, nil keeps runs pid-free.
    public init(responses: [String] = [], hangReads: Bool = false, stderrText: String = "", pid: Int32? = nil) {
        self.state = OSAllocatedUnfairLock(
            initialState: State(
                responses: responses,
                hang: hangReads,
                stderrText: stderrText,
                pid: pid
            )
        )
    }

    /// Queues one more response line for the next read.
    /// - Parameter line: Single JSON response line.
    public func enqueue(_ line: String) {
        state.withLock { fakeState in
            fakeState.responses.append(line)
        }
    }

    /// Toggles hang mode for upcoming reads.
    /// - Parameter hang: When true, reads report a timeout.
    public func setHang(_ hang: Bool) {
        state.withLock { fakeState in
            fakeState.hang = hang
        }
    }

    /// Sets the canned stderr tail for upcoming timeout errors.
    /// - Parameter text: Stderr text retained for the next hung read.
    public func setStderr(_ text: String) {
        state.withLock { fakeState in
            fakeState.stderrText = text
        }
    }

    /// Records one written line.
    /// - Parameter line: Single JSON document without a trailing newline.
    public func writeLine(_ line: String) async throws {
        state.withLock { fakeState in
            fakeState.written.append(line)
        }
    }

    /// Serves one queued line or reports a timeout when hanging.
    /// - Parameter timeout: Budget used for the timeout message and recording.
    /// - Returns: Next queued response line.
    public func readLine(timeout: TimeInterval) async throws -> String {
        let (hanging, tail): (Bool, String) = state.withLock { fakeState in
            fakeState.reads += 1
            fakeState.timeouts.append(timeout)
            return (fakeState.hang, fakeState.stderrText)
        }
        if hanging {
            throw EmailIMAPError.bridgeFailed(
                SessionLineTimeout.timeoutMessage(timeout: timeout, stderrTail: tail)
            )
        }
        return try state.withLock { fakeState in
            guard !fakeState.responses.isEmpty else {
                throw EmailIMAPError.bridgeFailed("IMAP session connection closed")
            }
            return fakeState.responses.removeFirst()
        }
    }

    /// Marks the fake terminated and counts the call.
    public func terminate() async {
        state.withLock { fakeState in
            fakeState.terminated = true
            fakeState.terminates += 1
        }
    }
}

/// Persistent read-only IMAP session owning one piped helper connection.
///
/// The actor serializes one in-flight command at a time: `start` spawns the
/// helper and opens with a 150s budget, `send` writes one line and reads one
/// response line with a 120s budget, and `close` sends close with a 10s budget
/// before terminating regardless. Concurrent starters coalesce onto one
/// in-flight open handshake, and concurrent senders await their turn so line
/// framing never interleaves. Every response reuses the one-shot envelope
/// shape so `EmailBridgeParsing` decodes session output verbatim. A command
/// failure terminates and surfaces without an internal respawn; the pooled
/// caller owns the single reconnect, preserving reconnect-once budgets, while
/// auth failures never retry. Close is non-throwing and idempotent, so a
/// second close no-ops. Named owner for open/command/close budgets plus all
/// session event emission points is this actor; event shapes live in
/// `MailSessionEventLog`.
public actor EmailIMAPSession {
    /// Budget for the opening exchange.
    ///
    /// Covers the worst-case bounded open: 4 addresses times 30s plus 30s login
    /// (150s total), so a stalled server surfaces its honest `Could not connect`
    /// error instead of a Swift timeout. Per-command 120s and close 10s stay
    /// unchanged.
    public static let openTimeoutSeconds: TimeInterval = 150
    /// Budget for each status, search, or fetch exchange.
    public static let commandTimeoutSeconds: TimeInterval = 120
    /// Budget for the best-effort close exchange.
    public static let closeTimeoutSeconds: TimeInterval = 10
    /// Environment variable overriding the interpreter, mirroring the gateway.
    public static let pythonEnvVar = "RUNEWEAVER_PYTHON_BIN"

    /// Resolved connection fields plus password held for re-open. Never logged.
    private let credentials: ResolvedEmailCredentials
    /// Resolved interpreter path, or nil for `python3` on `PATH`.
    private let pythonExecutable: String?
    /// Factory returning a fresh line transport per spawn. Nil means live pipes.
    private let factory: (@Sendable () async throws -> any SessionLineTransport)?
    /// JSONL event log receiving spawn, open, command, and close outcomes.
    ///
    /// Always on with no knob; only sizes, latencies, and outcomes ride the
    /// events so passwords and payload content never enter the log.
    private let eventLog: MailSessionEventLog
    /// Current line transport, nil when unstarted or torn down.
    private var transport: (any SessionLineTransport)?
    /// Last helper pid seen, retained for pool correlation after teardown.
    ///
    /// Command failures terminate the transport before the pool reads the pid,
    /// so this keeps the failing helper identity for `pool.evict` lines while
    /// the live transport still supplies the current pid when present.
    private var lastPid: Int32?
    /// Whether the open exchange has succeeded.
    private var started = false
    /// Whether close has run. Guards idempotent close.
    private var closed = false
    /// In-flight open task coalescing concurrent starters onto one handshake.
    private var inFlightOpen: Task<Void, Error>?
    /// Whether one command exchange currently owns the line framing.
    private var commandInFlight = false
    /// FIFO senders suspended while the slot is held, resumed in order on release.
    ///
    /// Actor reentrancy lets a second send arrive while the first awaits the
    /// helper; parking here serializes exchanges without executor spin so
    /// contended sends wake in order instead of busy-polling with added latency.
    private var commandWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    /// Waiter arrival order, oldest first, so release wakes the longest waiter.
    private var commandWaiterOrder: [UUID] = []

    /// Creates a session for one account with an optional transport seam.
    /// - Parameters:
    ///   - credentials: Resolved connection fields plus password for open and re-open.
    ///   - pythonExecutable: Explicit interpreter path, or nil to mirror gateway precedence.
    ///   - transportFactory: Fresh-transport factory per spawn, or nil for live pipes.
    ///   - eventLog: JSONL event log, defaulting to the live file sink.
    public init(
        credentials: ResolvedEmailCredentials,
        pythonExecutable: String? = nil,
        transportFactory: (@Sendable () async throws -> any SessionLineTransport)? = nil,
        eventLog: MailSessionEventLog = .live
    ) {
        self.credentials = credentials
        self.pythonExecutable = Self.resolvePythonExecutable(explicit: pythonExecutable)
        self.factory = transportFactory
        self.eventLog = eventLog
    }

    /// Current helper pid for pool correlation, nil when unstarted or hermetic.
    ///
    /// The pool layer reads this after a successful start so its `pool.open`,
    /// `pool.close`, and `pool.evict` lines carry the same pid as the session
    /// `session.spawn` line; timestamp plus pid then tie the two layers
    /// together while the session itself stays mailbox-agnostic. Falls back to
    /// the last seen pid after teardown so evict lines keep the failing helper
    /// identity even though the transport is already gone.
    public var processIdentifier: Int32? {
        transport?.processIdentifier ?? lastPid
    }

    /// Spawns the helper and opens the connection with a 150s budget.
    ///
    /// A second start after success no-ops; concurrent starters join one
    /// in-flight handshake instead of double-spawning. Starting after close
    /// reports that the session is no longer open. Open failures preserve the
    /// helper copy verbatim, including the one-shot `Could not connect` wording.
    /// The 150s bound outlasts the worst-case dial (4 addresses times 30s plus
    /// 30s login) so stalled servers stay honest server errors.
    /// - Throws: `EmailIMAPError.bridgeFailed` when closed or the open fails.
    public func start() async throws {
        guard !closed else {
            throw EmailIMAPError.bridgeFailed("session not open")
        }
        if started {
            return
        }
        if let flight = inFlightOpen {
            try await flight.value
            return
        }
        let flight = Task<Void, Error> {
            try await self.spawnAndOpen(timeout: Self.openTimeoutSeconds)
        }
        inFlightOpen = flight
        defer { inFlightOpen = nil }
        // A single waiter cancelling must never abort the shared handshake:
        // awaiting the shared flight propagates nothing into it, so a
        // cancelled starter stops waiting while the remaining starters still
        // join the same in-flight open.
        try await flight.value
    }

    /// Sends one command and returns the raw envelope bytes.
    ///
    /// Writes exactly one JSON line and consumes exactly one response line with
    /// a 120s budget. Concurrent callers await their turn so one command owns
    /// the line framing at a time. A `{ok false}` envelope throws `bridgeFailed`;
    /// a hung command terminates the helper and throws a transport-phrased
    /// timeout carrying the retained stderr tail. Any `bridgeFailed` terminates and surfaces without an internal
    /// respawn so the pooled caller owns retry; auth never retries per the
    /// shared retry classifier, which the outer open/start path consults to
    /// avoid reconnecting on auth, while `send` itself never branches on the
    /// failure kind.
    /// - Parameters:
    ///   - op: Session operation (`status`, `search`, or `fetch`).
    ///   - payload: String fields merged with `op` into one JSON document.
    /// - Returns: Raw response bytes for `EmailBridgeParsing` to decode.
    public func send(op: String, payload: [String: String] = [:]) async throws -> Data {
        try await acquireCommandSlot()
        defer { releaseCommandSlot() }
        guard !closed, started, transport != nil else {
            throw EmailIMAPError.bridgeFailed("session not open")
        }
        do {
            return try await exchange(op: op, payload: payload, timeout: Self.commandTimeoutSeconds)
        } catch let cancel as CancellationError {
            // Cooperative cancellation never terminates: the framing stays
            // pooled and the outer gateway skips eviction for cancels.
            throw cancel
        } catch let first as EmailIMAPError {
            if case .decodeFailed = first {
                throw first
            }
            guard case .bridgeFailed = first else {
                throw first
            }
            await terminateCurrent()
            throw first
        } catch {
            if error is CancellationError {
                throw error
            }
            throw error
        }
    }

    /// Acquires the single command slot in FIFO order, suspending while held.
    ///
    /// A free slot transfers immediately; otherwise the caller parks until release
    /// wakes it. Cancellation removes the waiter so a cancelled sender never steals
    /// the slot from its successor, and a close racing the wait surfaces promptly.
    private func acquireCommandSlot() async throws {
        if !commandInFlight {
            commandInFlight = true
            return
        }
        if closed {
            throw EmailIMAPError.bridgeFailed("session not open")
        }
        try Task.checkCancellation()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                commandWaiters[id] = continuation
                commandWaiterOrder.append(id)
            }
        } onCancel: {
            Task { [self, id] in
                await self.cancelCommandWaiter(id: id)
            }
        }
        // Ownership transfers on wake: a post-wait throw must release so the
        // next waiter is not parked forever behind a leaked slot.
        do {
            if closed {
                throw EmailIMAPError.bridgeFailed("session not open")
            }
            try Task.checkCancellation()
        } catch {
            releaseCommandSlot()
            throw error
        }
    }

    /// Releases the slot, waking the longest waiter with ownership transfer.
    ///
    /// The woken sender inherits the held slot so framing never interleaves; with
    /// no waiters the slot simply frees for the next arrival.
    private func releaseCommandSlot() {
        while !commandWaiterOrder.isEmpty {
            let id = commandWaiterOrder.removeFirst()
            guard let waiter = commandWaiters.removeValue(forKey: id) else { continue }
            waiter.resume()
            return
        }
        commandInFlight = false
    }

    /// Removes a cancelled waiter without disturbing slot ownership.
    /// - Parameter id: Waiter registration to withdraw.
    private func cancelCommandWaiter(id: UUID) {
        guard let waiter = commandWaiters.removeValue(forKey: id) else { return }
        commandWaiterOrder.removeAll(where: { $0 == id })
        waiter.resume(throwing: CancellationError())
    }

    /// Fails every parked sender when close wins the race.
    ///
    /// Lets a close during a contended wait surface promptly instead of leaving
    /// waiters parked until the slot frees after teardown.
    private func failCommandWaiters() {
        let pending = commandWaiterOrder
        commandWaiterOrder.removeAll()
        for id in pending {
            if let waiter = commandWaiters.removeValue(forKey: id) {
                waiter.resume(throwing: EmailIMAPError.bridgeFailed("session not open"))
            }
        }
    }
}

// MARK: - Mailbox Operations & Execution Helpers

extension EmailIMAPSession {
    /// Reads the STATUS snapshot for one mailbox over the open session.
    /// - Parameter mailbox: Mailbox to inspect.
    /// - Returns: Next UID plus validity token for fixed-window anchoring.
    public func status(mailbox: String) async throws -> EmailMailboxStatus {
        try EmailIMAPValidation.validateMailbox(mailbox)
        let trimmed = mailbox.trimmingCharacters(in: .whitespacesAndNewlines)
        let data = try await send(op: "status", payload: ["mailbox": trimmed])
        do {
            return try EmailBridgeParsing.parseStatusPayload(data)
        } catch let error as EmailIMAPError {
            throw error
        } catch {
            throw EmailIMAPError.decodeFailed(error.localizedDescription)
        }
    }

    /// Searches one mailbox over the open session.
    /// - Parameters:
    ///   - mailbox: Mailbox to search.
    ///   - query: Free-text query matched against subject, sender, and body.
    ///   - limit: Maximum hits, bounded to `1...50`.
    ///   - since: Inclusive lower bound, or nil for unbounded below.
    ///   - until: Exclusive upper bound, or nil for unbounded above.
    /// - Returns: Matching hits, newest first.
    public func search(mailbox: String, query: String, limit: Int, since: Date?, until: Date?) async throws -> [EmailSearchHit] {
        guard (1 ... EmailSearchArgs.maxLimit).contains(limit) else {
            throw EmailIMAPError.validationFailed(
                "Invalid search limit: limit must be 1...\(EmailSearchArgs.maxLimit)"
            )
        }
        try EmailIMAPValidation.validateSearchQuery(query)
        try EmailIMAPValidation.validateMailbox(mailbox)
        let trimmedMailbox = mailbox.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveQuery = EmailIMAPValidation.isAllQuery(trimmedQuery) ? "" : trimmedQuery
        var payload: [String: String] = ["mailbox": trimmedMailbox, "query": effectiveQuery, "limit": String(limit)]
        if let since {
            payload["since"] = TemporalFilter.imapDateString(from: since)
        }
        if let until {
            payload["until"] = TemporalFilter.imapUntilDateString(from: until)
        }
        let data = try await send(
            op: "search",
            payload: payload
        )
        do {
            let hits = try EmailBridgeParsing.parseSearchPayload(data)
            guard since != nil || until != nil else { return hits }
            let range = TemporalRange(since: since, until: until)
            return hits.filter { TemporalFilter.matches(date: EmailSearchMerge.date(of: $0), in: range) }
        } catch let error as EmailIMAPError {
            throw error
        } catch {
            throw EmailIMAPError.decodeFailed(error.localizedDescription)
        }
    }

    /// Searches one mailbox over the open session.
    /// - Parameters:
    ///   - mailbox: Mailbox to search.
    ///   - query: Free-text query matched against subject, sender, and body.
    ///   - limit: Maximum hits, bounded to `1...50`.
    /// - Returns: Matching hits, newest first.
    public func search(mailbox: String, query: String, limit: Int) async throws -> [EmailSearchHit] {
        try await search(mailbox: mailbox, query: query, limit: limit, since: nil, until: nil)
    }

    /// Fetches one message over the open session.
    /// - Parameters:
    ///   - mailbox: Mailbox holding the message.
    ///   - messageID: UID of the message to fetch.
    /// - Returns: Full message with peek-only body.
    public func fetch(mailbox: String, messageID: String) async throws -> EmailFullMessage {
        try EmailIMAPValidation.validateMessageID(messageID)
        try EmailIMAPValidation.validateMailbox(mailbox)
        let trimmedMailbox = mailbox.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedID = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
        let data = try await send(op: "fetch", payload: ["mailbox": trimmedMailbox, "messageID": trimmedID])
        do {
            return try EmailBridgeParsing.parseFetchPayload(data)
        } catch let error as EmailIMAPError {
            throw error
        } catch {
            throw EmailIMAPError.decodeFailed(error.localizedDescription)
        }
    }

    /// Best-effort close that never throws and idempotently terminates.
    ///
    /// Waits for an in-flight open handshake to settle before touching the
    /// transport so close never runs a second write/read pair on the same
    /// line framing while the open read is still pending, then sends close
    /// inside a 10s budget and terminates the helper regardless of the
    /// outcome. A second close no-ops without writing or reading, and a
    /// close after failure still terminates without throwing. The close event
    /// carries `clean` only when the handshake wrote and read without throwing;
    /// every other teardown records `terminate` with only the outcome logged.
    public func close() async {
        guard !closed else { return }
        closed = true
        failCommandWaiters()
        // Serialize against a mid-handshake open: the spawn assigns the
        // transport before suspending on its write/read, so touching the
        // transport here would run a second write/read pair on the same line
        // framing while the open read is still pending. Waiting for the
        // shared flight lets the handshake settle first; a close that arrived
        // mid-handshake then tears down the established transport once, and
        // the spawn's own closed check already terminates when close won.
        if let flight = inFlightOpen {
            _ = await flight.result
        }
        let account = credentials.accountName
        guard let current = transport else {
            started = false
            eventLog.logClose(account: account, pid: lastPid, outcome: "terminate")
            return
        }
        let pid = current.processIdentifier
        var clean = false
        do {
            let line = try encodeLine(op: "close", payload: [:])
            try await current.writeLine(line)
            _ = try await current.readLine(timeout: Self.closeTimeoutSeconds)
            // A throw-free handshake counts as clean even when the close line
            // itself reports failure; termination below still runs regardless.
            clean = true
        } catch {
            // Close stays non-throwing by design; termination below still runs.
            clean = false
        }
        await current.terminate()
        transport = nil
        started = false
        eventLog.logClose(account: account, pid: pid, outcome: clean ? "clean" : "terminate")
    }

    /// Resolves the interpreter mirroring the one-shot gateway precedence.
    ///
    /// Explicit whitespace handling matches `SubprocessIMAPGateway` and
    /// `SubprocessSMTPGateway`, which check the explicit path with a raw `isEmpty`
    /// while both sides trim-then-check the environment override; a whitespace-only
    /// explicit value therefore flows through as a configured path on both sides
    /// instead of collapsing to nil on one side only. The gateway files stay
    /// read-only here as they sit outside this task's scope.
    /// - Parameter explicit: Explicit path, or nil to consult the environment.
    /// - Returns: Explicit path, env override, or nil for `python3` on `PATH`.
    private static func resolvePythonExecutable(explicit: String?) -> String? {
        if let explicit, !explicit.isEmpty {
            return explicit
        }
        if let configured = ProcessInfo.processInfo.environment[Self.pythonEnvVar],
           !configured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return configured
        }
        return nil
    }

    /// Builds the open fields from resolved credentials without logging secrets.
    /// - Returns: String fields merged with `open` into one JSON document.
    private func openPayload() -> [String: String] {
        [
            "host": credentials.host,
            "port": String(credentials.port),
            "username": credentials.username,
            "password": credentials.password
        ]
    }

    /// Encodes one newline-delimited JSON document for the helper.
    /// - Parameters:
    ///   - op: Session operation.
    ///   - payload: String fields merged with `op`.
    /// - Returns: Single JSON line without a trailing newline.
    private func encodeLine(op: String, payload: [String: String]) throws -> String {
        var document = payload
        document["op"] = op
        let data = try JSONEncoder().encode(document)
        guard let line = String(data: data, encoding: .utf8) else {
            throw EmailIMAPError.bridgeFailed("Could not encode IMAP session request")
        }
        return line
    }

    /// Checks the one-shot envelope shape shared with the one-shot bridge.
    /// - Parameter line: Single response line from the helper.
    /// - Returns: Raw bytes when `ok` is true.
    private func checkedEnvelope(_ line: String) throws -> Data {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw EmailIMAPError.bridgeFailed("IMAP session connection closed")
        }
        let data = Data(trimmed.utf8)
        struct SessionEnvelope: Decodable {
            /// Whether the turn succeeded.
            let ok: Bool
            /// Error detail when `ok` is false.
            let error: String?
        }
        let envelope: SessionEnvelope
        do {
            envelope = try JSONDecoder().decode(SessionEnvelope.self, from: data)
        } catch {
            throw EmailIMAPError.decodeFailed(error.localizedDescription)
        }
        guard envelope.ok else {
            throw EmailIMAPError.bridgeFailed(envelope.error ?? "IMAP session command failed")
        }
        return data
    }

    /// Exact executable handed to exec for the current configuration.
    ///
    /// Mirrors the live pipe spawn so hermetic runs emit the same resolved
    /// interpreter without dialing; only the path rides the spawn event. An
    /// explicit empty path collapses to the `PATH` lookup like the transport
    /// initializer so the event cannot drift from the spawn.
    /// - Returns: Interpreter path or `/usr/bin/env` for `python3` on `PATH`.
    private func spawnExecutable() -> String {
        if let pythonExecutable, !pythonExecutable.isEmpty {
            return pythonExecutable
        }
        return "/usr/bin/env"
    }

    /// Argv summary for the spawn event without the script body.
    ///
    /// Single-sourced through the transport helper so construction and
    /// logging share one owner; only counts, previews, and sizes ride the
    /// event while the script body stays a size alone.
    /// - Returns: Count, preview, and script size for the spawn event.
    private func spawnArgvSummary() -> (count: Int, preview: String, scriptBytes: Int) {
        let scriptBytes = EmailIMAPSessionScript.source.utf8.count
        let summary = ProcessSessionLineTransport.argvSummary(
            pythonExecutable: pythonExecutable,
            scriptBytes: scriptBytes
        )
        return (count: summary.count, preview: summary.preview, scriptBytes: scriptBytes)
    }

    /// Builds the open sent shape directly without values.
    ///
    /// Sizes count UTF-8 bytes so multibyte spellings stay comparable with
    /// the wire `byteCount`; presence rides alongside so odd spellings stay
    /// diagnosable without ever carrying host, username, or password text.
    /// - Parameter lineByteCount: UTF-8 bytes written for the open line.
    /// - Returns: Sizes plus presence for the open sent event.
    private func openSentShape(lineByteCount: Int) -> MailSessionEventLog.OpenSentShape {
        MailSessionEventLog.OpenSentShape(
            byteCount: lineByteCount,
            host: credentials.host,
            port: credentials.port,
            username: credentials.username,
            password: credentials.password
        )
    }

    /// Strips exact credential values from an error detail before logging.
    ///
    /// The helper contract keeps identity out of envelopes, but verbatim
    /// helper details can still echo older `user@host:port` wordings; longest
    /// first replacement keeps host, username, and password values out of
    /// every logged field. The log layer additionally redacts email-shaped
    /// tokens as defense in depth.
    /// - Parameter detail: Raw error detail destined for the event log.
    /// - Returns: Detail with credential substrings replaced.
    private func sanitizedLogDetail(_ detail: String) -> String {
        var result = detail
        let secrets = [credentials.password, credentials.username, credentials.host]
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }
        for secret in secrets {
            result = result.replacingOccurrences(of: secret, with: "[redacted]")
        }
        return result
    }

    /// Reads one response line, logging the typed read outcome exactly once.
    ///
    /// Single owner for the read plus `session.read` emission so command and
    /// open paths cannot drift. Success logs `first-byte` with its size;
    /// transport failures log the classified `eof` or `timeout` outcome.
    /// Cooperative cancellation propagates unchanged with no read event so a
    /// cancelled wait never masquerades as a transport closure.
    /// - Parameters:
    ///   - transport: Line transport owning the framing.
    ///   - op: Session operation owning the read such as `open` or `search`.
    ///   - timeout: Seconds to wait for the single response line.
    ///   - pid: Helper child pid when known, nil for hermetic fakes.
    ///   - account: Owning account nickname.
    /// - Returns: Single response line without the trailing newline.
    private func loggedRead(
        from transport: any SessionLineTransport,
        op: String,
        timeout: TimeInterval,
        pid: Int32?,
        account: String
    ) async throws -> String {
        let readStart = Date()
        do {
            let response = try await transport.readLine(timeout: timeout)
            let waitMs = Date().timeIntervalSince(readStart) * 1000
            eventLog.logRead(
                account: account,
                pid: pid,
                op: op,
                outcome: .firstByte,
                waitMs: waitMs,
                bytes: response.utf8.count
            )
            return response
        } catch let cancel as CancellationError {
            throw cancel
        } catch let error as EmailIMAPError {
            let waitMs = Date().timeIntervalSince(readStart) * 1000
            eventLog.logRead(
                account: account,
                pid: pid,
                op: op,
                outcome: MailSessionEventLog.readOutcome(for: error),
                waitMs: waitMs
            )
            throw error
        } catch {
            if error is CancellationError {
                throw error
            }
            let waitMs = Date().timeIntervalSince(readStart) * 1000
            let mapped = EmailIMAPError.bridgeFailed("IMAP session read failed: \(error.localizedDescription)")
            eventLog.logRead(
                account: account,
                pid: pid,
                op: op,
                outcome: MailSessionEventLog.readOutcome(for: mapped),
                waitMs: waitMs
            )
            throw mapped
        }
    }

    /// Writes one line and reads one response line with a bounded wait.
    ///
    /// Named owner for command read detail: every command read emits one
    /// `session.read` line with first-byte, eof, or timeout plus its wait so
    /// stalls stay attributable without carrying payload bytes. Cooperative
    /// cancellation propagates unchanged with no command-failure event so the
    /// pooled caller skips its eviction path instead of treating a cancel as
    /// a transport closure.
    /// - Parameters:
    ///   - op: Session operation.
    ///   - payload: String fields merged with `op`.
    ///   - timeout: Seconds to wait for the single response line.
    /// - Returns: Raw envelope bytes when `ok` is true.
    private func exchange(op: String, payload: [String: String], timeout: TimeInterval) async throws -> Data {
        guard let current = transport, !closed, started else {
            throw EmailIMAPError.bridgeFailed("session not open")
        }
        let account = credentials.accountName
        let pid = current.processIdentifier
        let start = Date()
        do {
            let line: String
            do {
                line = try encodeLine(op: op, payload: payload)
            } catch {
                if error is CancellationError {
                    throw error
                }
                throw EmailIMAPError.bridgeFailed(
                    "Could not encode IMAP session request: \(error.localizedDescription)"
                )
            }
            do {
                try await current.writeLine(line)
            } catch let cancel as CancellationError {
                throw cancel
            } catch let error as EmailIMAPError {
                throw error
            } catch {
                if error is CancellationError {
                    throw error
                }
                throw EmailIMAPError.bridgeFailed("IMAP session write failed: \(error.localizedDescription)")
            }
            let response = try await loggedRead(from: current, op: op, timeout: timeout, pid: pid, account: account)
            let data = try checkedEnvelope(response)
            let latencyMs = Date().timeIntervalSince(start) * 1000
            // Only sizes, latencies, and outcomes ride the event; op names the
            // exchange while query text and payloads stay out of the log.
            eventLog.logCommand(account: account, pid: pid, op: op, latencyMs: latencyMs, ok: true)
            return data
        } catch let cancel as CancellationError {
            throw cancel
        } catch {
            if error is CancellationError {
                throw error
            }
            let latencyMs = Date().timeIntervalSince(start) * 1000
            let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            eventLog.logCommand(
                account: account,
                pid: pid,
                op: op,
                latencyMs: latencyMs,
                ok: false,
                error: sanitizedLogDetail(detail)
            )
            throw error
        }
    }

    /// Logs an open failure with write-to-line latency.
    ///
    /// Single owner for open-failure logging so factory-spawn, live-spawn,
    /// and open-exchange failures cannot drift; only the sanitized helper
    /// detail rides the event while payloads and identity stay out.
    /// - Parameters:
    ///   - pid: Helper child pid when known, nil for spawn failures.
    ///   - writeStart: Attempt start for latency measurement.
    ///   - error: Failure under test.
    private func logOpenFailure(pid: Int32?, writeStart: Date, error: Error) {
        let latencyMs = Date().timeIntervalSince(writeStart) * 1000
        let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        eventLog.logOpenResult(
            account: credentials.accountName,
            pid: pid,
            ok: false,
            error: sanitizedLogDetail(detail),
            latencyMs: latencyMs
        )
    }

    /// Terminates a fresh transport, emitting its stderr dump, and clears started state.
    ///
    /// Single owner for open-failure teardown so decode and generic paths
    /// cannot drift; the dump rides `session.stderr` before termination so a
    /// failed open still leaves its dying words. Empty dumps stay silent.
    /// - Parameter fresh: Fresh transport to dump, terminate, and clear.
    private func terminateAndClear(_ fresh: any SessionLineTransport) async {
        let dump = fresh.retainedStderr
        if !dump.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            eventLog.logStderr(account: credentials.accountName, pid: fresh.processIdentifier, stderr: dump)
        }
        await fresh.terminate()
        transport = nil
        started = false
    }

    /// Spawns a fresh transport and opens with a bounded wait.
    ///
    /// Failures terminate the fresh transport before throwing so a bad open
    /// never leaks a half-open helper. The helper copy surfaces sanitized so
    /// identity never enters the log. A close racing the handshake terminates
    /// instead of leaving a started session behind. Spawn, sent, read,
    /// result, and stderr events carry only the executable, argv summary,
    /// field shapes, latencies, and outcomes so the password and request
    /// payload never enter the log. Cooperative cancellation propagates
    /// unchanged with no failure event so the pooled caller skips eviction.
    /// Named owner for open read detail is this actor.
    /// - Parameter timeout: Seconds to wait for the single open response.
    private func spawnAndOpen(timeout: TimeInterval) async throws {
        let account = credentials.accountName
        let attemptStart = Date()
        let next: any SessionLineTransport
        if let factory {
            do {
                next = try await factory()
            } catch let cancel as CancellationError {
                throw cancel
            } catch {
                if error is CancellationError {
                    throw error
                }
                logOpenFailure(pid: nil, writeStart: attemptStart, error: error)
                if let sessionError = error as? EmailIMAPError {
                    throw sessionError
                }
                throw EmailIMAPError.pythonUnavailable(
                    "Could not launch python3 for IMAP session access: \(error.localizedDescription)"
                )
            }
        } else {
            do {
                next = try ProcessSessionLineTransport(
                    pythonExecutable: pythonExecutable,
                    scriptSource: EmailIMAPSessionScript.source
                )
            } catch let cancel as CancellationError {
                throw cancel
            } catch {
                if error is CancellationError {
                    throw error
                }
                logOpenFailure(pid: nil, writeStart: attemptStart, error: error)
                if let sessionError = error as? EmailIMAPError {
                    throw sessionError
                }
                throw EmailIMAPError.pythonUnavailable(
                    "Could not launch python3 for IMAP session access: \(error.localizedDescription)"
                )
            }
        }
        transport = next
        let pid = next.processIdentifier
        lastPid = pid
        let executable = spawnExecutable()
        let argv = spawnArgvSummary()
        eventLog.logSpawn(
            account: account,
            pid: pid,
            executable: executable,
            argvCount: argv.count,
            argvPreview: argv.preview,
            scriptBytes: argv.scriptBytes
        )
        let writeStart = Date()
        do {
            let line = try encodeLine(op: "open", payload: openPayload())
            do {
                try await next.writeLine(line)
            } catch let cancel as CancellationError {
                throw cancel
            } catch {
                if error is CancellationError {
                    throw error
                }
                throw error
            }
            // Only shapes ride the event; the open line holds the password
            // and stays out of the log.
            eventLog.logOpenSent(
                account: account,
                pid: pid,
                shape: openSentShape(lineByteCount: line.utf8.count)
            )
            let response = try await loggedRead(from: next, op: "open", timeout: timeout, pid: pid, account: account)
            let latencyMs = Date().timeIntervalSince(writeStart) * 1000
            _ = try checkedEnvelope(response)
            guard !closed else {
                await next.terminate()
                transport = nil
                started = false
                eventLog.logOpenResult(
                    account: account,
                    pid: pid,
                    ok: false,
                    error: "session not open",
                    latencyMs: latencyMs
                )
                throw EmailIMAPError.bridgeFailed("session not open")
            }
            eventLog.logOpenResult(account: account, pid: pid, ok: true, error: nil, latencyMs: latencyMs)
            started = true
        } catch let cancel as CancellationError {
            // A cancelled open is not a transport failure: tear down the
            // half-open helper without a failure event or stderr dump so no
            // `open.result ok:false` implies a server fault, then propagate
            // the original cancellation for the pooled caller to skip evict.
            await next.terminate()
            transport = nil
            started = false
            throw cancel
        } catch {
            if error is CancellationError {
                await next.terminate()
                transport = nil
                started = false
                throw error
            }
            // A decode failure still records the open outcome with its detail;
            // the caller sees the same sanitized error it would without logging.
            logOpenFailure(pid: pid, writeStart: writeStart, error: error)
            await terminateAndClear(next)
            if let sessionError = error as? EmailIMAPError {
                throw sessionError
            }
            throw EmailIMAPError.bridgeFailed("IMAP session open failed: \(error.localizedDescription)")
        }
    }

    /// Terminates the current transport and clears started state.
    private func terminateCurrent() async {
        if let current = transport {
            await current.terminate()
        }
        transport = nil
        started = false
    }
}

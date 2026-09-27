// Rune Weaver Tools — Persistent read-only IMAP session actor with framing, timeouts, and once-reconnect.
//
// Purpose: keeps one IMAP connection open across status, search, and fetch turns so
// repeated reads avoid redialing. Scope: read-only newline-delimited JSON framing
// over a piped python3 helper, with per-command budgets and a single reconnect.
// Architectural role: session lifecycle owner; line framing rides the transport
// seam so live Process pipes and hermetic fakes share one contract. Every read
// stays peek-only and every response reuses the one-shot envelope shape.

import Foundation
import RuneWeaverCore

/// Line framing seam for the persistent IMAP session.
///
/// The actor writes one JSON document per line and consumes exactly one response
/// line per command. Live Process pipes and hermetic fakes share this contract
/// so framing, timeout, and reconnect behavior stays testable without dialing.
public protocol SessionLineTransport: Sendable {
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

/// Exactly-once resume state for one cancellable session line read.
///
/// The blocking pipe reader, timeout timer, and task cancellation race; only
/// the first finisher resumes the continuation while losers exit silently once
/// teardown unblocks the stray reader. A winner arriving before the
/// continuation publishes stores its result so a late publish still delivers
/// it instead of hanging the read.
///
/// Sendable proof: every access to `continuation`, `published`, `settled`,
/// `stored`, and `timer` holds `mutex` via `withLock`. `set`, `setTimer`, and
/// the private `resume(with:)` are the only mutating paths; each captures the
/// continuation and timer under the lock, then resumes or cancels outside the
/// lock so a reentrant resume can never deadlock. `CheckedContinuation` and
/// `DispatchWorkItem` are not statically `Sendable`, so the class stays
/// `@unchecked Sendable` with the lock as the single synchronization point.
private final class SessionLineReadState: @unchecked Sendable {
    /// Published continuation awaiting the winning racer.
    private var continuation: CheckedContinuation<String, Error>?
    /// Whether `set` already published the continuation.
    private var published = false
    /// Whether a racer already settled the verdict.
    private var settled = false
    /// Winning result stored for a late publish when cancellation wins first.
    private var stored: Result<String, Error>?
    /// Pending timeout work cancelled once any racer wins.
    private var timer: DispatchWorkItem?
    /// Guards continuation, verdict, stored result, and timer.
    private let mutex = NSLock()

    /// Publishes the continuation, delivering an early winning result when present.
    /// - Parameter continuation: Continuation awaiting the read verdict.
    func set(_ continuation: CheckedContinuation<String, Error>) {
        let early: Result<String, Error>? = mutex.withLock {
            guard !published else { return nil }
            published = true
            if settled {
                return stored
            }
            self.continuation = continuation
            return nil
        }
        if let early {
            continuation.resume(with: early)
        }
    }

    /// Records the timeout work so a winning reader or cancellation can drop it.
    /// - Parameter item: Scheduled timeout work.
    func setTimer(_ item: DispatchWorkItem) {
        let shouldCancel: Bool = mutex.withLock {
            if settled {
                return true
            }
            timer = item
            return false
        }
        if shouldCancel {
            item.cancel()
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

    private struct ResumeOutcome {
        let won: Bool
        let held: CheckedContinuation<String, Error>?
        let pending: DispatchWorkItem?
    }

    /// Settles the read unless already settled, cancelling the pending timer.
    /// - Parameter result: Winning verdict.
    /// - Returns: True when this caller won, false for late losers.
    private func resume(with result: Result<String, Error>) -> Bool {
        let outcome = mutex.withLock {
            guard !settled else { return ResumeOutcome(won: false, held: nil, pending: nil) }
            settled = true
            stored = result
            let held = continuation
            continuation = nil
            let pending = timer
            timer = nil
            return ResumeOutcome(won: true, held: held, pending: pending)
        }
        outcome.pending?.cancel()
        if let held = outcome.held {
            held.resume(with: result)
        }
        return outcome.won
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
private final class SessionStderrTail: @unchecked Sendable {
    /// Guards retained bytes.
    private let lock = NSLock()
    /// Newest retained bytes, capped at the transport bound.
    private var data = Data()
    /// Maximum bytes retained.
    private let cap: Int

    /// Creates a tail store with a byte cap.
    /// - Parameter cap: Maximum bytes retained.
    init(cap: Int) {
        self.cap = cap
    }

    /// Appends a chunk, keeping only the newest capped bytes.
    /// - Parameter chunk: Fresh stderr bytes from the drain.
    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.withLock {
            data.append(chunk)
            if data.count > cap {
                data.removeSubrange(0 ..< (data.count - cap))
            }
        }
    }

    /// Returns the retained tail as trimmed text.
    /// - Returns: Trimmed stderr text, or empty when nothing was captured.
    func snapshot() -> String {
        lock.withLock {
            String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

/// Live Process-pipe line transport for the persistent session helper.
///
/// Spawns `python3 -u -c` with piped stdin and stdout so each command is one
/// unbuffered JSON line each way. Standard error drains in the background so
/// helper diagnostics never block a read. All secrets stay in the written line;
/// nothing here logs connection fields. Named owner for stderr retention: this
/// transport keeps the last 500 stderr bytes and appends them to timeout
/// errors so a stalled helper still leaves its dying words.
///
/// Sendable proof: `Process` and `FileHandle` are not `Sendable`, so the class
/// stays `@unchecked Sendable`. All handle and process touches hold `ioLock`:
/// `writeLine` performs the stdin write under `ioLock`, `terminate` performs
/// `terminate` plus stdin/stdout/stderr closes under `ioLock` exactly once via
/// `didTerminate`, the termination handler closes the stderr drain under
/// `ioLock` after checking `didTerminate` so it serializes against
/// `terminate` instead of racing its guarded closes, and `blockingReadLine`
/// captures the stdout handle under `ioLock` then reads outside the lock so
/// a hung read never stalls termination. A close racing a read surfaces as a
/// mapped `bridgeFailed` instead of undefined behavior, and the `pending`
/// buffer stays under `pendingLock`. The stderr drain is cancelled by closing
/// its handle, and the child is reaped with `waitUntilExit` off the
/// cooperative pool.
public final class ProcessSessionLineTransport: SessionLineTransport, @unchecked Sendable {
    /// Maximum stderr characters retained for timeout diagnostics.
    ///
    /// Keeps timeout errors readable while preserving the helper's last words;
    /// the session script contract keeps secrets out of stderr, and this bound
    /// holds even if that contract ever changes.
    public static let maxStderrTailChars = 500
    /// Underlying helper process. Touched only while holding `ioLock`.
    private let process: Process
    /// Writable stdin handle. Written and closed only while holding `ioLock`.
    private let stdinHandle: FileHandle
    /// Readable stdout handle. Captured under `ioLock`, read outside it.
    private let stdoutHandle: FileHandle
    /// Readable stderr handle. Drained off-pool; closed under `ioLock`.
    private let stderrHandle: FileHandle
    /// Retained stderr tail feeding timeout errors. Appended only by the drain.
    private let stderrTail: SessionStderrTail
    /// Buffered stdout bytes awaiting a newline boundary.
    private var pending = Data()
    /// Guards buffered stdout bytes across concurrent readers.
    private let pendingLock = NSLock()
    /// Whether termination already ran. Guarded by `ioLock`.
    private var didTerminate = false
    /// Guards process, stdin/stdout/stderr handles, and termination state.
    private let ioLock = NSLock()

    /// Spawns the session helper with piped stdio.
    /// - Parameters:
    ///   - pythonExecutable: Explicit interpreter path, or nil for `python3` on `PATH`.
    ///   - scriptSource: Python source executed via `-u -c`.
    /// - Throws: `EmailIMAPError.pythonUnavailable` when the spawn fails.
    public init(pythonExecutable: String?, scriptSource: String) throws {
        let spawned = Process()
        if let pythonExecutable, !pythonExecutable.isEmpty {
            spawned.executableURL = URL(fileURLWithPath: pythonExecutable)
            spawned.arguments = ["-u", "-c", scriptSource]
        } else {
            spawned.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            spawned.arguments = ["python3", "-u", "-c", scriptSource]
        }
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        spawned.standardInput = stdinPipe
        spawned.standardOutput = stdoutPipe
        spawned.standardError = stderrPipe
        let stderrReading = stderrPipe.fileHandleForReading
        let tailStore = SessionStderrTail(cap: Self.maxStderrTailChars)
        self.stderrTail = tailStore
        // Drain diagnostics off-pool so stderr never blocks the helper while
        // retaining the last words for timeout errors. Closing this handle in
        // `terminate` (or on natural exit) unblocks the drain, which is the
        // cancellation mechanism for this blocking read.
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
            }
        }
        self.process = spawned
        self.stdinHandle = stdinPipe.fileHandleForWriting
        self.stdoutHandle = stdoutPipe.fileHandleForReading
        self.stderrHandle = stderrReading
        // Reap the child without blocking the caller: the handler closes the
        // stderr drain handle under `ioLock` after checking `didTerminate` so
        // it serializes against `terminate` instead of racing its guarded closes.
        self.process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.ioLock.withLock {
                guard !self.didTerminate else { return }
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
    /// The stdin write holds `ioLock` so it serializes against `terminate`
    /// closes; a write racing teardown maps to a transport-phrased error.
    /// - Parameter line: Single JSON document without a trailing newline.
    public func writeLine(_ line: String) async throws {
        let payload = Data((line + "\n").utf8)
        do {
            try ioLock.withLock {
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
        let state = SessionLineReadState()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                state.set(continuation)
                DispatchQueue.global(qos: .utility).async { [self] in
                    do {
                        let line = try self.blockingReadLine()
                        state.resume(returning: line)
                    } catch {
                        state.resume(throwing: error)
                    }
                }
                let timer = DispatchWorkItem { [self] in
                    // Read the retained tail at fire time so diagnostics written
                    // just before the stall still ride the timeout detail.
                    let tail = self.stderrTail.snapshot()
                    state.resume(
                        throwing: EmailIMAPError.bridgeFailed(
                            SessionLineTimeout.timeoutMessage(timeout: timeout, stderrTail: tail)
                        )
                    )
                }
                state.setTimer(timer)
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + budget, execute: timer)
                if Task.isCancelled {
                    state.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            state.resume(throwing: CancellationError())
        }
    }

    /// Terminates the helper and closes stdio exactly once, then reaps off-pool.
    ///
    /// Holds `ioLock` across the termination flag, `terminate`, and all three
    /// handle closes so concurrent writers serialize instead of writing into a
    /// half-closed pipe. Closing stdout/stderr unblocks the stray blocking
    /// reader and the stderr drain; `waitUntilExit` runs off the cooperative
    /// pool so teardown never stalls the executor.
    public func terminate() async {
        let shouldReap: Bool = ioLock.withLock {
            guard !didTerminate else { return false }
            didTerminate = true
            process.terminate()
            try? stdinHandle.close()
            try? stdoutHandle.close()
            try? stderrHandle.close()
            return true
        }
        guard shouldReap else { return }
        // `self` is `@unchecked Sendable`, so capturing it keeps the reap
        // closure `Sendable`; `process` itself is an immutable let whose only
        // mutable operations already ran under `ioLock` above.
        DispatchQueue.global(qos: .utility).async { [self] in
            self.process.waitUntilExit()
        }
    }

    /// Blocks the calling thread until one newline-terminated line arrives.
    ///
    /// The stdout handle is captured under `ioLock` and read outside it so a
    /// hung helper never holds the lock while `terminate` waits to close. A
    /// close racing the read throws and maps to a transport-phrased closure
    /// error; buffered bytes stay under `pendingLock`.
    /// - Returns: Single line without the trailing newline.
    private func blockingReadLine() throws -> String {
        while true {
            let buffered: Data? = pendingLock.withLock {
                guard let newline = pending.firstIndex(of: 10) else {
                    return nil
                }
                let slice = Data(pending.prefix(upTo: newline))
                pending.removeSubrange(pending.startIndex ... newline)
                return slice
            }
            if let buffered {
                guard let line = String(data: buffered, encoding: .utf8) else {
                    throw EmailIMAPError.decodeFailed("IMAP session returned non-UTF8 line")
                }
                return line
            }
            let stdoutReading: FileHandle = ioLock.withLock { stdoutHandle }
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
            pendingLock.withLock {
                pending.append(chunk)
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
/// Sendable proof: every queue, counter, flag, budget, and stderr access holds `mutex`
/// via `withLock` or `lock`/`unlock`. All stored state is value types, and the
/// lock is the single synchronization point across `writeLine`, `readLine`,
/// `enqueue`, `setHang`, `setStderr`, and `terminate`. The class stays `@unchecked Sendable`
/// only because the compiler cannot verify the manual lock discipline.
public final class FakeSessionLineTransport: SessionLineTransport, @unchecked Sendable {
    /// Every line written through `writeLine`, in order.
    public var writtenLines: [String] {
        mutex.lock()
        defer { mutex.unlock() }
        return _written
    }

    /// Number of `writeLine` calls observed.
    public var writeCount: Int {
        mutex.lock()
        defer { mutex.unlock() }
        return _written.count
    }

    /// Number of `readLine` calls observed.
    public var readCount: Int {
        mutex.lock()
        defer { mutex.unlock() }
        return _reads
    }

    /// Number of `terminate` calls observed.
    public var terminateCount: Int {
        mutex.lock()
        defer { mutex.unlock() }
        return _terminates
    }

    /// Whether `terminate` has run at least once.
    public var isTerminated: Bool {
        mutex.lock()
        defer { mutex.unlock() }
        return _terminated
    }

    /// Requested read budgets in call order, for budget assertions.
    public var readTimeouts: [TimeInterval] {
        mutex.lock()
        defer { mutex.unlock() }
        return _timeouts
    }

    /// Canned stderr tail surfaced on timeouts, mirroring the live drain.
    public var stderrText: String {
        mutex.lock()
        defer { mutex.unlock() }
        return _stderrText
    }

    /// Guards in-memory queues and counters.
    private let mutex = NSLock()
    /// Recorded writes in arrival order.
    private var _written: [String] = []
    /// Queued response lines served first-in first-out.
    private var _responses: [String]
    /// When true, reads report a timeout without serving the queue.
    private var _hang: Bool
    /// Canned stderr tail appended to timeout errors via the shared helper.
    private var _stderrText: String
    /// Whether termination ran.
    private var _terminated = false
    /// Termination call count.
    private var _terminates = 0
    /// Read call count.
    private var _reads = 0
    /// Requested read budgets in call order.
    private var _timeouts: [TimeInterval] = []

    /// Creates an in-memory transport with canned responses.
    /// - Parameters:
    ///   - responses: Response lines served first-in first-out, one per read.
    ///   - hangReads: When true, every read reports a timeout instead of serving the queue.
    ///   - stderrText: Canned stderr tail appended to timeout errors, mirroring the live drain.
    public init(responses: [String] = [], hangReads: Bool = false, stderrText: String = "") {
        self._responses = responses
        self._hang = hangReads
        self._stderrText = stderrText
    }

    /// Queues one more response line for the next read.
    /// - Parameter line: Single JSON response line.
    public func enqueue(_ line: String) {
        mutex.withLock {
            _responses.append(line)
        }
    }

    /// Toggles hang mode for upcoming reads.
    /// - Parameter hang: When true, reads report a timeout.
    public func setHang(_ hang: Bool) {
        mutex.withLock {
            _hang = hang
        }
    }

    /// Sets the canned stderr tail for upcoming timeout errors.
    ///
    /// Mirrors the live stderr drain through the shared timeout helper so
    /// timeout copy stays identical between the live and hermetic paths.
    /// - Parameter text: Stderr text retained for the next hung read.
    public func setStderr(_ text: String) {
        mutex.withLock {
            _stderrText = text
        }
    }

    /// Records one written line.
    /// - Parameter line: Single JSON document without a trailing newline.
    public func writeLine(_ line: String) async throws {
        mutex.withLock {
            _written.append(line)
        }
    }

    /// Serves one queued line or reports a timeout when hanging.
    ///
    /// An empty queue surfaces as a closed connection so tests fail fast
    /// instead of blocking. Hang mode mirrors the live timeout wording exactly,
    /// including the retained stderr tail, without waiting out the budget,
    /// keeping timeout tests hermetic and fast.
    /// - Parameter timeout: Budget used for the timeout message and recording.
    /// - Returns: Next queued response line.
    public func readLine(timeout: TimeInterval) async throws -> String {
        let (hanging, tail): (Bool, String) = mutex.withLock {
            _reads += 1
            _timeouts.append(timeout)
            return (_hang, _stderrText)
        }
        if hanging {
            throw EmailIMAPError.bridgeFailed(
                SessionLineTimeout.timeoutMessage(timeout: timeout, stderrTail: tail)
            )
        }
        return try mutex.withLock {
            guard !_responses.isEmpty else {
                throw EmailIMAPError.bridgeFailed("IMAP session connection closed")
            }
            return _responses.removeFirst()
        }
    }

    /// Marks the fake terminated and counts the call.
    public func terminate() async {
        mutex.withLock {
            _terminated = true
            _terminates += 1
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
/// second close no-ops. Named owner for open/command/close budgets is this actor.
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
    /// Current line transport, nil when unstarted or torn down.
    private var transport: (any SessionLineTransport)?
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
    public init(
        credentials: ResolvedEmailCredentials,
        pythonExecutable: String? = nil,
        transportFactory: (@Sendable () async throws -> any SessionLineTransport)? = nil
    ) {
        self.credentials = credentials
        self.pythonExecutable = Self.resolvePythonExecutable(explicit: pythonExecutable)
        self.factory = transportFactory
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
        return try await withTaskCancellationHandler {
            try await flight.value
        } onCancel: {
            flight.cancel()
        }
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
        } catch let first as EmailIMAPError {
            if case .decodeFailed = first {
                throw first
            }
            guard case .bridgeFailed = first else {
                throw first
            }
            await terminateCurrent()
            throw first
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
    /// Sends close inside a 10s budget, then terminates the helper regardless
    /// of the outcome. A second close no-ops without writing or reading, and a
    /// close after failure still terminates without throwing.
    public func close() async {
        guard !closed else { return }
        closed = true
        failCommandWaiters()
        guard let current = transport else {
            started = false
            return
        }
        do {
            let line = try encodeLine(op: "close", payload: [:])
            try await current.writeLine(line)
            _ = try? await current.readLine(timeout: Self.closeTimeoutSeconds)
        } catch {
            // Close stays non-throwing by design; termination below still runs.
        }
        await current.terminate()
        transport = nil
        started = false
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

    /// Writes one line and reads one response line with a bounded wait.
    /// - Parameters:
    ///   - op: Session operation.
    ///   - payload: String fields merged with `op`.
    ///   - timeout: Seconds to wait for the single response line.
    /// - Returns: Raw envelope bytes when `ok` is true.
    private func exchange(op: String, payload: [String: String], timeout: TimeInterval) async throws -> Data {
        guard let current = transport, !closed, started else {
            throw EmailIMAPError.bridgeFailed("session not open")
        }
        let line: String
        do {
            line = try encodeLine(op: op, payload: payload)
        } catch {
            throw EmailIMAPError.bridgeFailed(
                "Could not encode IMAP session request: \(error.localizedDescription)"
            )
        }
        do {
            try await current.writeLine(line)
        } catch let error as EmailIMAPError {
            throw error
        } catch {
            throw EmailIMAPError.bridgeFailed("IMAP session write failed: \(error.localizedDescription)")
        }
        let response: String
        do {
            response = try await current.readLine(timeout: timeout)
        } catch let error as EmailIMAPError {
            throw error
        } catch {
            throw EmailIMAPError.bridgeFailed("IMAP session read failed: \(error.localizedDescription)")
        }
        return try checkedEnvelope(response)
    }

    /// Spawns a fresh transport and opens with a bounded wait.
    ///
    /// Failures terminate the fresh transport before throwing so a bad open
    /// never leaks a half-open helper. The helper copy surfaces verbatim. A
    /// close racing the handshake terminates instead of leaving a started
    /// session behind.
    /// - Parameter timeout: Seconds to wait for the single open response.
    private func spawnAndOpen(timeout: TimeInterval) async throws {
        let next: any SessionLineTransport
        if let factory {
            do {
                next = try await factory()
            } catch let error as EmailIMAPError {
                throw error
            } catch {
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
            } catch let error as EmailIMAPError {
                throw error
            } catch {
                throw EmailIMAPError.pythonUnavailable(
                    "Could not launch python3 for IMAP session access: \(error.localizedDescription)"
                )
            }
        }
        transport = next
        do {
            let line = try encodeLine(op: "open", payload: openPayload())
            try await next.writeLine(line)
            let response = try await next.readLine(timeout: timeout)
            _ = try checkedEnvelope(response)
            guard !closed else {
                await next.terminate()
                transport = nil
                started = false
                throw EmailIMAPError.bridgeFailed("session not open")
            }
            started = true
        } catch {
            await next.terminate()
            transport = nil
            started = false
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

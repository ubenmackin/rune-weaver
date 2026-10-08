// Rune Weaver Core — Shared primitives for bounded subprocess execution.
//
// Purpose: single-source capped pipe buffers, drain and budget values, and
// one-shot continuation gates. Scope: used by the bounded runner and the
// JSON-RPC subprocess bridge so timeouts, caps, termination, and cancellation
// stay converged; the live-process box stays single-sourced as
// `BoundedProcessRunner.ProcessBox` and is shared by both paths. Architectural
// role: convergence point preventing lock, latch, and snapshot drift across
// callers; every bounded child enforces the same budgets and settles its
// continuation exactly once.

import Foundation
import os

/// Caps bounding pipe drains.
/// Groups both limits so drain helpers take one value instead of two ints.
/// Intent: one shared shape keeps the bounded runner and the plugin bridge from
/// drifting on cap ordering; callers clamp to at least one byte so empty caps
/// fail closed instead of allowing unbounded growth.
public struct ProcessDrainLimits: Sendable {
    /// Retained stdout cap in bytes.
    public let stdout: Int
    /// Retained stderr cap in bytes.
    public let stderr: Int

    /// Creates drain caps.
    public init(stdout: Int, stderr: Int) {
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// Budgets bounding one invocation.
/// Groups timeout and output cap so termination mapping stays narrow.
/// Intent: timeout wins over caps in every mapper, so the flag plus the stored
/// budgets must travel together; the plugin call identity travels separately so
/// the same budgets serve both generic helpers and JSON-RPC responses.
public struct ProcessBudgets: Sendable {
    /// Timeout in seconds before the child is terminated.
    public let timeoutSeconds: TimeInterval
    /// Stdout cap in bytes before the child is terminated.
    public let maxOutputBytes: Int

    /// Creates invocation budgets.
    public init(timeoutSeconds: TimeInterval, maxOutputBytes: Int) {
        self.timeoutSeconds = timeoutSeconds
        self.maxOutputBytes = maxOutputBytes
    }
}

/// Snapshot of retained pipe bytes plus latched cap flags.
/// Exists so pipe drains return a named value instead of a wide tuple, and so
/// both the generic runner and the plugin bridge read the same latched state.
/// Invariant: flags latch on first excess and never clear, so a racy second
/// append cannot un-trip a cap the mapper already observed.
public struct CappedPipeSnapshot: Sendable {
    /// Retained stdout bytes up to the cap.
    public var stdout = Data()
    /// Retained stderr bytes up to the diagnostic cap.
    public var stderr = Data()
    /// Whether stdout produced more than its cap.
    public var stdoutExceeded = false
    /// Whether stderr produced more than its cap.
    public var stderrExceeded = false

    /// Creates an empty snapshot.
    public init(stdout: Data = Data(), stderr: Data = Data(), stdoutExceeded: Bool = false, stderrExceeded: Bool = false) {
        self.stdout = stdout
        self.stderr = stderr
        self.stdoutExceeded = stdoutExceeded
        self.stderrExceeded = stderrExceeded
    }
}

/// Sendable accumulation for concurrent pipe handlers so readability closures
/// never capture mutable state across executors. Caps latch on first excess so
/// a malicious child cannot force an unbounded allocation before truncation.
/// Intent: one shared buffer keeps the bounded runner and the plugin bridge on
/// the same append, latch, and snapshot ordering. Invariant: every mutation
/// stays behind the unfair lock, which is held only for short value moves and
/// never across termination or resume.
public final class CappedPipeBuffers: Sendable {
    private struct State: Sendable {
        var stdout = Data()
        var stderr = Data()
        var stdoutExceeded = false
        var stderrExceeded = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Creates empty buffers.
    public init() {}

    /// Appends stdout, latching excess past the cap.
    /// - Returns: True when the cap tripped and the caller must terminate the child.
    public func appendOutput(_ chunk: Data, limit: Int) -> Bool {
        guard !chunk.isEmpty else { return false }
        return state.withLock { current in
            if current.stdoutExceeded {
                return true
            }
            current.stdout.append(chunk)
            if current.stdout.count > limit {
                current.stdoutExceeded = true
                return true
            }
            return false
        }
    }

    /// Appends stderr, latching excess past the diagnostic cap.
    /// - Returns: True when the cap tripped and the caller must terminate the child.
    public func appendError(_ chunk: Data, limit: Int) -> Bool {
        guard !chunk.isEmpty else { return false }
        return state.withLock { current in
            if current.stderrExceeded {
                return true
            }
            current.stderr.append(chunk)
            if current.stderr.count > limit {
                current.stderrExceeded = true
                return true
            }
            return false
        }
    }

    /// Whether stdout tripped its cap.
    public var stdoutExceeded: Bool {
        state.withLock { $0.stdoutExceeded }
    }

    /// Whether stderr tripped its cap.
    public var stderrExceeded: Bool {
        state.withLock { $0.stderrExceeded }
    }

    /// Snapshots retained bytes plus latched flags for the terminal result.
    public func snapshot() -> CappedPipeSnapshot {
        state.withLock {
            CappedPipeSnapshot(
                stdout: $0.stdout,
                stderr: $0.stderr,
                stdoutExceeded: $0.stdoutExceeded,
                stderrExceeded: $0.stderrExceeded
            )
        }
    }
}

/// Shared pipe-drain, budget, timeout, and input helpers converging the bounded runner and the plugin bridge.
/// Single-sources readability attachment, tail draining, timeout-over-cap mapping, timeout spawning, and tolerant
/// input writes so the two runners cannot drift on caps, budgets, or termination ordering.
/// Intent: one implementation owns the budgets; per-runner shims only adapt result shapes and log levels.
/// Invariant: timeout wins over caps in `mapTermination`; the timeout task only terminates and never resumes, keeping
/// cancellation distinguishable via the flag plus the outer cancellation check; locks are held only for short value
/// moves and never across termination or resume.
public enum ProcessDrainHelpers: Sendable {
    /// Attaches concurrent readability handlers draining both pipes under caps.
    /// Caps terminate via the shared box without capturing the child directly,
    /// so handlers never move non-Sendable state across executors.
    public static func attachDrains(
        stdoutPipe: Pipe,
        stderrPipe: Pipe,
        buffers: CappedPipeBuffers,
        limits: ProcessDrainLimits,
        box: BoundedProcessRunner.ProcessBox
    ) {
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                return
            }
            if buffers.appendOutput(chunk, limit: limits.stdout) {
                box.terminateIfRunning()
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                return
            }
            if buffers.appendError(chunk, limit: limits.stderr) {
                box.terminateIfRunning()
            }
        }
    }

    /// Drains bytes the handlers missed between the last callback and exit.
    /// Enforces caps before reporting so tail bytes respect the same budgets.
    public static func drainTail(
        stdoutPipe: Pipe,
        stderrPipe: Pipe,
        buffers: CappedPipeBuffers,
        limits: ProcessDrainLimits
    ) {
        let tailOut = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        if !tailOut.isEmpty {
            _ = buffers.appendOutput(tailOut, limit: limits.stdout)
        }
        let tailErr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        if !tailErr.isEmpty {
            _ = buffers.appendError(tailErr, limit: limits.stderr)
        }
    }

    /// Maps terminal state to retained bytes, preserving timeout-over-cap ordering.
    /// Throws the same budget errors for every caller so timeout versus cap stays converged;
    /// callers adapt the snapshot into their own result shape with their own wording.
    public static func mapTermination(
        buffers: CappedPipeBuffers,
        didTimeOut: Bool,
        budgets: ProcessBudgets
    ) throws -> CappedPipeSnapshot {
        if didTimeOut {
            throw BoundedProcessError.timedOut(
                "Process timed out after \(Int(budgets.timeoutSeconds))s and was terminated."
            )
        }
        if buffers.stdoutExceeded {
            throw BoundedProcessError.outputLimitExceeded(
                "Process output exceeded the \(budgets.maxOutputBytes)-byte limit and was terminated."
            )
        }
        return buffers.snapshot()
    }

    /// Starts the structured timeout child for one invocation.
    /// Only terminates and never resumes, keeping timeout versus cancel
    /// distinguishable via the flag plus the outer cancellation check.
    public static func startTimeout(
        clampedTimeout: TimeInterval,
        timedOut: OSAllocatedUnfairLock<Bool>,
        box: BoundedProcessRunner.ProcessBox
    ) -> Task<Void, Never> {
        Task {
            do {
                try await Task.sleep(nanoseconds: UInt64(clampedTimeout * 1_000_000_000))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            timedOut.withLock { $0 = true }
            box.terminateIfRunning()
        }
    }

    /// Writes caller input unless empty, tolerating an early-closed stdin.
    /// The newline flag covers the JSON-RPC framing newline without forking the write path;
    /// the warning flag preserves the bridge diagnostic level while the runner stays debug.
    public static func writeInput(stdinPipe: Pipe, inputData: Data?, appendNewline: Bool = false, logAsWarning: Bool = false) {
        guard let inputData, !inputData.isEmpty else {
            try? stdinPipe.fileHandleForWriting.close()
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            defer {
                try? stdinPipe.fileHandleForWriting.close()
            }
            do {
                try stdinPipe.fileHandleForWriting.write(contentsOf: inputData)
                if appendNewline {
                    try stdinPipe.fileHandleForWriting.write(contentsOf: Data("\n".utf8))
                }
            } catch {
                if logAsWarning {
                    RuneWeaverLog.tools.warning("SubprocessToolBridge: stdin write terminated early: \(error)")
                } else {
                    RuneWeaverLog.tools.debug("BoundedProcessRunner: Child closed stdin before write completed: \(error.localizedDescription)")
                }
            }
        }
    }
}

/// One-shot gate ensuring a throwing continuation resumes exactly once.
/// Only the first claim wins; late arrivals observe the stored outcome instead
/// of racing. Supports both eager continuations (published at init) and late
/// continuations (published via `set` after a racer already won), so DNS-style
/// timeouts and process termination share the same once semantics.
/// Intent: single generic replaces the per-caller did-resume plus unfair-lock
/// copies; timeout and cancellation extensions compose around this gate instead
/// of copying it. Invariant: the lock is held only for short value moves, never
/// across a continuation resume or task cancel, so racers cannot deadlock while
/// settling the verdict.
public final class CheckedOnce<Success: Sendable>: Sendable {
    private struct State: Sendable {
        var continuation: CheckedContinuation<Success, Error>?
        var didResume = false
        var result: Result<Success, Error>?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Creates an empty gate awaiting its continuation.
    public init() {}

    /// Creates a gate holding a continuation.
    /// - Parameter continuation: Continuation to resume once.
    public init(_ continuation: CheckedContinuation<Success, Error>) {
        state.withLock { $0.continuation = continuation }
    }

    /// Whether a racer already settled the verdict.
    public var isSettled: Bool {
        state.withLock { $0.didResume }
    }

    /// Publishes the continuation, delivering the stored outcome when a racer won early.
    /// - Parameter continuation: Continuation to resume once.
    public func set(_ continuation: CheckedContinuation<Success, Error>) {
        let settled: Result<Success, Error>?? = state.withLock { lockState -> Result<Success, Error>?? in
            if lockState.didResume {
                return .some(lockState.result)
            }
            lockState.continuation = continuation
            return nil
        }
        if let settled {
            // Every resume stores its result before releasing the lock, so a
            // settled gate always carries a value; a missing value stays
            // unsettled here rather than resuming with a forged outcome.
            if let result = settled {
                continuation.resume(with: result)
            }
        }
    }

    /// Resumes with success unless already resumed.
    public func resume(returning value: Success) {
        resume(with: .success(value))
    }

    /// Resumes with failure unless already resumed.
    public func resume(throwing error: Error) {
        resume(with: .failure(error))
    }

    /// Resumes with a result unless already resumed.
    /// Stores the winning value first so a late `set` still observes it.
    public func resume(with result: Result<Success, Error>) {
        let held = state.withLock { lockState -> CheckedContinuation<Success, Error>? in
            guard !lockState.didResume else { return nil }
            lockState.didResume = true
            lockState.result = result
            let held = lockState.continuation
            lockState.continuation = nil
            return held
        }
        held?.resume(with: result)
    }
}

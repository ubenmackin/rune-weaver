// Rune Weaver Core — Bounded async drain helpers for the shared process runner.

import Foundation
import os

extension BoundedProcessRunner {
    /// Attaches concurrent readability handlers for the async runner.
    /// Thin adapter over the shared drain helper so both runners enforce the same caps
    /// without duplicating handler logic; termination still flows via the shared box.
    static func attachAsyncDrains(
        stdoutPipe: Pipe,
        stderrPipe: Pipe,
        buffers: CappedPipeBuffers,
        limits: ProcessDrainLimits,
        box: ProcessBox
    ) {
        ProcessDrainHelpers.attachDrains(
            stdoutPipe: stdoutPipe,
            stderrPipe: stderrPipe,
            buffers: buffers,
            limits: limits,
            box: box
        )
    }

    /// Drains bytes the handlers missed between the last callback and exit.
    /// Thin adapter preserving the same cap enforcement as the shared tail drain.
    static func drainBoundedTail(
        stdoutPipe: Pipe,
        stderrPipe: Pipe,
        buffers: CappedPipeBuffers,
        limits: ProcessDrainLimits
    ) {
        ProcessDrainHelpers.drainTail(
            stdoutPipe: stdoutPipe,
            stderrPipe: stderrPipe,
            buffers: buffers,
            limits: limits
        )
    }

    /// Maps terminal state to a result, preserving timeout-over-cap ordering.
    /// Adapts the shared snapshot verdict into the runner result with the runner wording.
    static func mapBoundedTermination(
        status: Int32,
        buffers: CappedPipeBuffers,
        didTimeOut: Bool,
        budgets: ProcessBudgets
    ) throws -> BoundedProcessResult {
        let snapshot = try ProcessDrainHelpers.mapTermination(
            buffers: buffers,
            didTimeOut: didTimeOut,
            budgets: budgets
        )
        return BoundedProcessResult(
            exitCode: status,
            stdout: snapshot.stdout,
            stderr: snapshot.stderr
        )
    }

    /// Starts the structured timeout child for the async runner.
    /// Thin adapter so timeout spawning stays single-sourced; only terminates and never
    /// resumes, keeping timeout versus cancel distinguishable via the flag plus the outer check.
    static func startBoundedTimeout(
        clampedTimeout: TimeInterval,
        timedOut: OSAllocatedUnfairLock<Bool>,
        box: ProcessBox
    ) -> Task<Void, Never> {
        ProcessDrainHelpers.startTimeout(
            clampedTimeout: clampedTimeout,
            timedOut: timedOut,
            box: box
        )
    }

    /// Writes caller input unless empty, tolerating an early-closed stdin.
    /// Thin adapter over the shared tolerant write without the bridge framing newline.
    static func writeBoundedInput(stdinPipe: Pipe, inputData: Data?) {
        ProcessDrainHelpers.writeInput(stdinPipe: stdinPipe, inputData: inputData, appendNewline: false)
    }
}

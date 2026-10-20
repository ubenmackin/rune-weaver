// Rune Weaver Core — Subprocess JSON-RPC drain helpers for plugin execution.

import Foundation
import os

extension SubprocessToolBridge {
    func attachSubprocessDrains(
        stdoutPipe: Pipe,
        stderrPipe: Pipe,
        buffers: CappedPipeBuffers,
        limits: ProcessDrainLimits,
        processBox: BoundedProcessRunner.ProcessBox
    ) {
        // Thin adapter over the shared drain helper so a child producing large
        // stderr never fills the pipe buffer and deadlocks while the parent
        // waits for stdout EOF; caps still terminate via the shared box.
        ProcessDrainHelpers.attachDrains(
            stdoutPipe: stdoutPipe,
            stderrPipe: stderrPipe,
            buffers: buffers,
            limits: limits,
            box: processBox
        )
    }

    func drainSubprocessTail(
        stdoutPipe: Pipe,
        stderrPipe: Pipe,
        buffers: CappedPipeBuffers,
        limits: ProcessDrainLimits
    ) {
        // Thin adapter preserving the same cap enforcement as the shared tail drain.
        ProcessDrainHelpers.drainTail(
            stdoutPipe: stdoutPipe,
            stderrPipe: stderrPipe,
            buffers: buffers,
            limits: limits
        )
    }

    func mapSubprocessTermination(
        terminationStatus: Int32,
        buffers: CappedPipeBuffers,
        didTimeOut: Bool,
        budgets: ProcessBudgets,
        callID: String,
        resolvedSecrets: [String] = []
    ) -> ToolOutput {
        // Shared verdict preserves timeout-over-cap ordering; the bridge only
        // adapts budget failures into JSON-RPC failure wording with the call identity.
        do {
            let snapshot = try ProcessDrainHelpers.mapTermination(
                buffers: buffers,
                didTimeOut: didTimeOut,
                budgets: budgets
            )
            return parseSubprocessResponse(
                stdoutData: snapshot.stdout,
                stderrData: snapshot.stderr,
                terminationStatus: terminationStatus,
                maxOutputBytes: budgets.maxOutputBytes,
                callID: callID,
                resolvedSecrets: resolvedSecrets
            )
        } catch let bridgeError as BoundedProcessError {
            switch bridgeError {
            case .timedOut:
                return .failure(
                    "Tool execution timed out after \(Int(budgets.timeoutSeconds))s.",
                    callID: callID
                )
            case .outputLimitExceeded:
                return .failure(
                    "Tool output exceeded the \(budgets.maxOutputBytes)-byte limit and was terminated.",
                    callID: callID
                )
            case let .launchFailed(detail):
                return .failure(detail, callID: callID)
            }
        } catch {
            return .failure(
                "Tool execution failed: \(error.localizedDescription)",
                callID: callID
            )
        }
    }

    func startSubprocessTimeout(
        clampedTimeout: TimeInterval,
        timedOut: OSAllocatedUnfairLock<Bool>,
        processBox: BoundedProcessRunner.ProcessBox
    ) -> Task<Void, Never> {
        // Thin adapter so timeout spawning stays single-sourced; it only
        // terminates and never resumes, avoiding any double-resume with termination.
        ProcessDrainHelpers.startTimeout(
            clampedTimeout: clampedTimeout,
            timedOut: timedOut,
            box: processBox
        )
    }

    func writeSubprocessInput(stdinPipe: Pipe, inputData: Data) {
        // Thin adapter adding the JSON-RPC framing newline via the shared tolerant write.
        ProcessDrainHelpers.writeInput(
            stdinPipe: stdinPipe,
            inputData: inputData,
            appendNewline: true,
            logAsWarning: true
        )
    }
}

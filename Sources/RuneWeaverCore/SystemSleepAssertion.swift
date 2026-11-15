// Rune Weaver Core — Scoped macOS power assertion preventing idle and DarkWake sleep mid-run.

import Foundation
import os
#if os(macOS) && canImport(IOKit)
    import IOKit.pwr_mgt
#endif

/// Holds active macOS power assertions for the lifetime of an asynchronous operation.
///
/// Releasing is idempotent; ``deinit`` acts as a fallback if callers omit an explicit
/// `release()`. Under normal flow callers release deterministically via `defer`.
public final class SystemSleepAssertion: @unchecked Sendable {
    /// Factory signature for acquiring a sleep assertion, injectable in tests.
    public typealias Acquire = @Sendable (String) -> SystemSleepAssertion?

    private struct State: @unchecked Sendable {
        var activity: NSObjectProtocol?
        #if os(macOS) && canImport(IOKit)
            var systemSleepAssertionID: IOPMAssertionID?
        #endif
        var onRelease: (@Sendable () -> Void)?
    }

    private let state: OSAllocatedUnfairLock<State>

    #if os(macOS) && canImport(IOKit)
        private init(
            activity: NSObjectProtocol?,
            systemSleepAssertionID: IOPMAssertionID?,
            onRelease: (@Sendable () -> Void)? = nil
        ) {
            self.state = OSAllocatedUnfairLock(initialState: State(
                activity: activity,
                systemSleepAssertionID: systemSleepAssertionID,
                onRelease: onRelease
            ))
        }
    #else
        private init(
            activity: NSObjectProtocol?,
            onRelease: (@Sendable () -> Void)? = nil
        ) {
            self.state = OSAllocatedUnfairLock(initialState: State(
                activity: activity,
                onRelease: onRelease
            ))
        }
    #endif

    deinit {
        release()
    }

    /// Acquires macOS idle-sleep and system-sleep assertions for the given reason.
    /// - Parameter reason: Human-readable diagnostic description surfaced in `pmset -g assertions`.
    /// - Returns: A retained assertion token, or `nil` when running on unsupported platforms.
    public static func acquire(reason: String) -> SystemSleepAssertion? {
        #if os(macOS)
            // Keep both idle user sleep (`sleep 1`) and AC DarkWake maintenance drops
            // from suspending an active multi-minute agent turn.
            let activity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .suddenTerminationDisabled],
                reason: reason
            )
            #if canImport(IOKit)
                var assertionID: IOPMAssertionID = 0
                let status = IOPMAssertionCreateWithName(
                    kIOPMAssertionTypePreventSystemSleep as CFString,
                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                    reason as CFString,
                    &assertionID
                )
                let createdID: IOPMAssertionID? = if status == kIOReturnSuccess {
                    assertionID
                } else {
                    nil
                }
                if createdID == nil {
                    RuneWeaverLog.scheduler.debug(
                        "SystemSleepAssertion: PreventSystemSleep assertion unavailable (IOReturn \(status)); holding ProcessInfo activity only."
                    )
                }
                return SystemSleepAssertion(activity: activity, systemSleepAssertionID: createdID)
            #else
                return SystemSleepAssertion(activity: activity)
            #endif
        #else
            _ = reason
            return nil
        #endif
    }

    /// Creates a synthetic assertion token for unit tests to observe deterministic release.
    public static func testToken(onRelease: @escaping @Sendable () -> Void) -> SystemSleepAssertion {
        #if os(macOS) && canImport(IOKit)
            SystemSleepAssertion(activity: nil, systemSleepAssertionID: nil, onRelease: onRelease)
        #else
            SystemSleepAssertion(activity: nil, onRelease: onRelease)
        #endif
    }

    /// Releases held power assertions idempotently.
    public func release() {
        let taken: State = state.withLock { current in
            let snapshot = current
            current.activity = nil
            #if os(macOS) && canImport(IOKit)
                current.systemSleepAssertionID = nil
            #endif
            current.onRelease = nil
            return snapshot
        }
        #if os(macOS)
            if let activity = taken.activity {
                ProcessInfo.processInfo.endActivity(activity)
            }
            #if canImport(IOKit)
                if let assertionID = taken.systemSleepAssertionID {
                    IOPMAssertionRelease(assertionID)
                }
            #endif
        #endif
        taken.onRelease?()
    }
}

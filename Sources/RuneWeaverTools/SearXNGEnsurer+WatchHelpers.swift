// Rune Weaver Tools — SearXNG readiness watch stages.

import Foundation

extension SearXNGEnsurer {
    /// Consecutive-5xx streak across watch ticks.
    public struct ReadinessSickState: Sendable, Equatable {
        /// Consecutive countable 5xx responses so far.
        var count: Int = 0
        /// Status at the last countable 5xx, nil until one arrives.
        var status: Int?
        /// Capped body tail at the last countable 5xx.
        var tail: String = ""

        /// Creates an empty streak before the first probe.
        public init(count: Int = 0, status: Int? = nil, tail: String = "") {
            self.count = count
            self.status = status
            self.tail = tail
        }
    }

    /// Loop progress carried across watch ticks.
    /// Holds the last legible container hint for the backstop plus the sick
    /// streak, so staged helpers share one value without extra parameters.
    public struct ReadinessLoopState: Sendable, Equatable {
        /// Last legible container hint, unknown until a probe proves otherwise.
        var lastState: String
        /// Consecutive-5xx streak entering the next tick.
        var sick: ReadinessSickState

        /// Creates loop progress from its parts.
        public init(lastState: String, sick: ReadinessSickState = ReadinessSickState()) {
            self.lastState = lastState
            self.sick = sick
        }
    }

    /// Probe bundle shared by every watch stage. Carries the same four probes the entry point
    /// receives so staged helpers stay within the parameter budget instead of repeating each
    /// closure.
    public struct ReadinessWatchProbes: Sendable {
        /// Probe answering true once HTTP responds 2xx/3xx.
        let isReachable: @Sendable () async -> Bool
        /// Probe classifying the tracked entry each tick.
        let containerState: @Sendable () async -> ContainerReadinessSnapshot
        /// Probe fetching the capped logs tail on terminal or backstop.
        let containerLogs: @Sendable () async -> String
        /// Rich HTTP probe driving success and sickness, nil for legacy mode.
        let httpProbe: (@Sendable () async -> HTTPProbeSnapshot)?

        /// Creates a probe bundle from the entry-point closures.
        public init(
            isReachable: @Sendable @escaping () async -> Bool,
            containerState: @Sendable @escaping () async -> ContainerReadinessSnapshot,
            containerLogs: @Sendable @escaping () async -> String,
            httpProbe: (@Sendable () async -> HTTPProbeSnapshot)? = nil
        ) {
            self.isReachable = isReachable
            self.containerState = containerState
            self.containerLogs = containerLogs
            self.httpProbe = httpProbe
        }
    }

    /// Advances the sick streak for one probe response.
    public static func advancedSickState(_ state: ReadinessSickState, with probe: HTTPProbeSnapshot) -> ReadinessSickState {
        var next = state
        next.count = nextConsecutiveServerErrorCount(
            current: state.count,
            statusCode: probe.statusCode,
            bodyTail: probe.bodyTail
        )
        if probe.isCountableServerError {
            next.status = probe.statusCode
            next.tail = probe.bodyTail
        }
        return next
    }

    /// Builds the sick fail-fast outcome once the streak trips. Shares one gate plus one detail
    /// shape so the initial, tick, and final stages never drift on threshold or banner text.
    public static func sickFailFastOutcome(for state: ReadinessSickState) -> ReadinessWatchOutcome? {
        guard shouldFailFastOnConsecutiveServerErrors(state.count), let code = state.status else {
            return nil
        }
        let detail = readinessServerErrorDetail(statusCode: code, bodyTail: state.tail)
        return ReadinessWatchOutcome(
            succeeded: false,
            failureDetail: detail,
            lastState: readinessServerErrorStateText(statusCode: code),
            logsTail: state.tail,
            cancelled: false
        )
    }

    /// Builds the terminal-state outcome with the logs tail. Kept beside the tick so the loop and
    /// the tests share one failure shape instead of duplicating the detail call.
    public static func terminalWatchOutcome(snapshot: ContainerReadinessSnapshot, tail: String) -> ReadinessWatchOutcome {
        let detail = readinessFailureDetail(
            stateText: snapshot.rawState,
            logsTail: tail,
            timedOut: false,
            exitCode: snapshot.exitCode
        )
        return ReadinessWatchOutcome(
            succeeded: false,
            failureDetail: detail,
            lastState: snapshot.rawState,
            logsTail: tail,
            cancelled: false
        )
    }

    /// Builds the backstop outcome with the last state plus logs tail. Timeout-only when nothing
    /// ever answered, since the tail arrives empty.
    public static func backstopWatchOutcome(lastState: String, tail: String, backstop: Double) -> ReadinessWatchOutcome {
        let detail = readinessFailureDetail(
            stateText: "last state \(lastState)",
            logsTail: tail,
            timedOut: true,
            timeoutSeconds: backstop
        )
        return ReadinessWatchOutcome(
            succeeded: false,
            failureDetail: detail,
            lastState: lastState,
            logsTail: tail,
            cancelled: false
        )
    }

    /// Runs the fast initial probe before the ticking loop. An already-answering engine returns
    /// success at once; a countable sick streak starting at zero can already trip when the threshold
    /// is one.
    public static func initialWatchOutcome(probes: ReadinessWatchProbes) async -> (outcome: ReadinessWatchOutcome?, sick: ReadinessSickState) {
        if Task.isCancelled {
            return (.cancelledOutcome, ReadinessSickState())
        }
        var sick = ReadinessSickState()
        if let httpProbe = probes.httpProbe {
            let initial = await httpProbe()
            if Task.isCancelled {
                return (.cancelledOutcome, sick)
            }
            if initial.isSuccess {
                if Task.isCancelled {
                    return (.cancelledOutcome, sick)
                }
                return (ReadinessWatchOutcome(succeeded: true, lastState: "running", logsTail: ""), sick)
            }
            sick = advancedSickState(sick, with: initial)
            if let sickOutcome = sickFailFastOutcome(for: sick) {
                if Task.isCancelled {
                    return (.cancelledOutcome, sick)
                }
                return (sickOutcome, sick)
            }
            return (nil, sick)
        }
        if await probes.isReachable() {
            if Task.isCancelled {
                return (.cancelledOutcome, sick)
            }
            return (ReadinessWatchOutcome(succeeded: true, lastState: "running", logsTail: ""), sick)
        }
        return (nil, sick)
    }

    /// Runs one tick of the HTTP plus sick stage inside the loop.
    public static func tickHTTPOutcome(
        probes: ReadinessWatchProbes,
        lastState: String,
        sick: ReadinessSickState
    ) async -> (outcome: ReadinessWatchOutcome?, sick: ReadinessSickState) {
        if Task.isCancelled {
            return (.cancelledOutcome, sick)
        }
        var next = sick
        if let httpProbe = probes.httpProbe {
            let probe = await httpProbe()
            if Task.isCancelled {
                return (.cancelledOutcome, next)
            }
            if probe.isSuccess {
                if Task.isCancelled {
                    return (.cancelledOutcome, next)
                }
                return (ReadinessWatchOutcome(succeeded: true, lastState: lastState, logsTail: ""), next)
            }
            if Task.isCancelled {
                return (.cancelledOutcome, next)
            }
            next = advancedSickState(next, with: probe)
            if let sickOutcome = sickFailFastOutcome(for: next) {
                if Task.isCancelled {
                    return (.cancelledOutcome, next)
                }
                return (sickOutcome, next)
            }
            return (nil, next)
        }
        if await probes.isReachable() {
            if Task.isCancelled {
                return (.cancelledOutcome, next)
            }
            return (ReadinessWatchOutcome(succeeded: true, lastState: lastState, logsTail: ""), next)
        }
        return (nil, next)
    }

    /// Runs one tick of the terminal-state stage inside the loop. Fetches the logs tail only when
    /// the snapshot proves the entry will never answer, so slow boots never pay a logs fetch per
    /// tick.
    public static func tickTerminalOutcome(snapshot: ContainerReadinessSnapshot, probes: ReadinessWatchProbes) async -> ReadinessWatchOutcome? {
        if Task.isCancelled {
            return .cancelledOutcome
        }
        guard snapshot.state.isTerminal else {
            return nil
        }
        let tail = await probes.containerLogs()
        if Task.isCancelled {
            return .cancelledOutcome
        }
        return terminalWatchOutcome(snapshot: snapshot, tail: tail)
    }

    /// Ticks the shared poll loop until the backstop elapses.
    public static func pollWatchLoop(
        pollInterval: UInt64,
        backstop: Double,
        state: ReadinessLoopState,
        probes: ReadinessWatchProbes
    ) async -> (outcome: ReadinessWatchOutcome?, state: ReadinessLoopState) {
        if Task.isCancelled {
            return (.cancelledOutcome, state)
        }
        let budget = Duration.nanoseconds(Int64(backstop * 1_000_000_000))
        let clock = ContinuousClock()
        let start = clock.now
        var current = state
        while clock.now - start < budget {
            if Task.isCancelled {
                return (.cancelledOutcome, current)
            }
            let ticked = await tickHTTPOutcome(probes: probes, lastState: current.lastState, sick: current.sick)
            current.sick = ticked.sick
            if let outcome = ticked.outcome {
                return (outcome, current)
            }
            if Task.isCancelled {
                return (.cancelledOutcome, current)
            }
            let snapshot = await probes.containerState()
            if Task.isCancelled {
                return (.cancelledOutcome, current)
            }
            if let terminal = await tickTerminalOutcome(snapshot: snapshot, probes: probes) {
                return (terminal, current)
            }
            if snapshot.state != .unknown {
                current.lastState = snapshot.rawState
            }
            do {
                try await Task.sleep(nanoseconds: pollInterval)
            } catch is CancellationError {
                return (.cancelledOutcome, current)
            } catch {
                return (.cancelledOutcome, current)
            }
        }
        return (nil, current)
    }
}

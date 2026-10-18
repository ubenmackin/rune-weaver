// Rune Weaver Core — Proactive surfacing gate for background interruptions.

import Foundation

/// Background outcome kinds eligible for proactive surfacing.
public enum ProactiveEventKind: String, Sendable, Codable, CaseIterable, Equatable {
    /// A scheduler job finished without parking or throwing.
    case schedulerOk
    /// A scheduler or goal turn threw.
    case schedulerError
    /// A goal advancement finished one routine step.
    case goalStepDone
    /// A goal reached its terminal achieved state.
    case goalAchieved
    /// A goal parked awaiting owner input.
    case goalNeedsInput
    /// A goal step stalled on an obstacle.
    case goalBlocked
    /// A scheduler or goal turn parked awaiting approval.
    case runParked
    /// A scheduler or goal turn ran out of tool iteration budget before completing.
    case runBudgetExceeded = "run_budget_exceeded"
    /// A proactive suggestion the Wayfinder engine proposed outside any turn.
    case ideaProposed

    /// Whether this kind breaks through under the milestones policy. Milestones are
    /// owner-meaningful transitions (goal completions, input needs, blocks), failures, and parked
    /// turns.
    var isMilestone: Bool {
        switch self {
        case .schedulerError, .goalAchieved, .goalNeedsInput, .goalBlocked, .runParked, .runBudgetExceeded:
            true
        case .schedulerOk, .goalStepDone, .ideaProposed:
            false
        }
    }
}

/// One background outcome offered to the surfacing gate.
public struct ProactiveEvent: Sendable, Equatable {
    /// What happened.
    public let kind: ProactiveEventKind
    /// Job or goal title identifying the source.
    public let title: String
    /// Bounded outcome preview for headlines and judge context.
    public let preview: String

    /// Longest outcome preview kept for judge context and default headlines.
    public static let maxPreviewChars = 160
    /// Longest interruption headline shown on badges and notifications.
    public static let maxHeadlineChars = 90

    /// Creates an event, bounding the outcome to the shared preview budget. - outcome: Full outcome
    /// text (response, error detail, or prompt fallback).
    public init(kind: ProactiveEventKind, title: String, outcome: String) {
        self.kind = kind
        self.title = title
        self.preview = Self.makePreview(outcome)
    }

    /// Truncates an outcome to the shared preview budget.
    /// - Parameter text: Full outcome text.
    /// - Returns: Trimmed prefix capped at 160 characters with an ellipsis when cut.
    public static func makePreview(_ text: String) -> String {
        let preview = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return preview.count > maxPreviewChars ? String(preview.prefix(maxPreviewChars)) + "…" : preview
    }

    /// Clamps a headline to the interruption budget.
    public static func clampHeadline(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > maxHeadlineChars ? String(trimmed.prefix(maxHeadlineChars)) : trimmed
    }
}

/// Judge verdict for one routine outcome.
public struct SurfacingVerdict: Sendable, Equatable {
    /// Whether the outcome should interrupt the owner.
    public let surface: Bool
    /// Short headline for the interruption frame, clamped at use.
    public let headline: String

    /// Creates a verdict. surface: Whether to interrupt.
    public init(surface: Bool, headline: String) {
        self.surface = surface
        self.headline = headline
    }
}

/// Judge closure consulted once per guarded routine success.
public typealias ProactiveJudge = @Sendable (ProactiveEvent) async throws -> SurfacingVerdict

/// Interruption gate for background scheduler and goal outcomes.
public actor OutcomeGate {
    /// Surfacing mode from `[proactive]`.
    private let mode: ProactiveMode
    /// Seconds the guarded judge may spend before the gate fails open.
    private let judgeTimeoutSeconds: Int
    /// Model judge for guarded routine successes, nil for deterministic modes.
    private let judge: ProactiveJudge?

    /// Creates a gate. The range is owned by load-time validation (1-120); this stores the value
    /// verbatim so misconfiguration surfaces instead of silently clamping.
    public init(
        mode: ProactiveMode = .all,
        judgeTimeoutSeconds: Int = ProactiveConfig.defaultJudgeTimeoutSeconds,
        judge: ProactiveJudge? = nil
    ) {
        self.mode = mode
        self.judgeTimeoutSeconds = judgeTimeoutSeconds
        self.judge = judge
    }

    /// Current surfacing mode.
    public var currentMode: ProactiveMode {
        mode
    }

    /// Decides whether an event interrupts the owner. `all` surfaces everything, `off` surfaces
    /// nothing, `milestones` surfaces milestone kinds only, and `guarded` adds one bounded judge
    /// call for routine scheduler successes.
    public func decide(event: ProactiveEvent) async -> (surface: Bool, headline: String) {
        let fallback = defaultHeadline(for: event)
        switch mode {
        case .all:
            return (true, fallback)
        case .off:
            return (false, fallback)
        case .milestones:
            return event.kind.isMilestone ? (true, fallback) : (false, fallback)
        case .guarded:
            if event.kind.isMilestone {
                return (true, fallback)
            }
            guard event.kind == .schedulerOk, let judge else {
                return (false, fallback)
            }
            do {
                let verdict = try await withTimeout(seconds: Double(judgeTimeoutSeconds)) {
                    try await judge(event)
                }
                let raw = verdict.headline.trimmingCharacters(in: .whitespacesAndNewlines)
                let headline = raw.isEmpty ? fallback : ProactiveEvent.clampHeadline(raw)
                return (verdict.surface, headline)
            } catch {
                return (true, fallback)
            }
        }
    }

    /// Default headline when no judge headline applies.
    private func defaultHeadline(for event: ProactiveEvent) -> String {
        let base = event.preview.isEmpty ? event.title : event.preview
        return ProactiveEvent.clampHeadline(base)
    }

    /// Races an operation against a timeout deadline.
    private func withTimeout<T: Sendable>(
        seconds: Double,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(1, seconds) * 1_000_000_000))
                throw CancellationError()
            }
            guard let result = try await group.next() else {
                throw CancellationError()
            }
            group.cancelAll()
            return result
        }
    }
}

// Dashboard interruption frames ride the shared proactive_message wire shape in WSWire as
// WSProactiveMessageFrame, so worker turns and REST share one encoding.

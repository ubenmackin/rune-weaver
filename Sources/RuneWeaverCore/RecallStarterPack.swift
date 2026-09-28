// Rune Weaver Core — Always-on starter context for turn footing.

import Foundation

/// Freshness for starter footing, keeping a missing store distinct from an enabled-but-empty one.
///
/// A missing document store means the owner never opted in, while an empty
/// store or an epoch watermark means indexing is on but holds nothing fresh
/// to cite, so the pack renders each posture with its own honest copy.
public enum StarterIndexState: Sendable, Equatable {
    /// No document store is wired, so index footing stays opted out.
    case disabled
    /// A store is wired but holds no documents or no fresh watermark yet.
    case empty
    /// A store is wired and carries a fresh watermark for the pack to cite.
    case ready(Date)
}

/// Always-on starter footing for every turn: owner name plus index freshness.
///
/// Trusted verbatim context (never labeled) injected as a second system
/// message beside automatic recall. Profile names come from the `name`
/// preference; the index watermark is an ISO-8601 instant, `empty` when the
/// store is enabled but holds nothing fresh, or `disabled` when no store is wired.
public enum RecallStarterPack: Sendable {
    /// Ceiling for any single pack line; live budgets can only tighten it.
    public static let maxLineChars = 200
    /// Ceiling for the whole pack block; live budgets can only tighten it.
    public static let maxTotalChars = 600

    /// Per-line budget for one pack, tightening the ceiling when recall is small.
    ///
    /// Recall budgets bound the whole turn, so a small `perHitChars` shrinks
    /// starter lines to match; the default budgets leave the fixed ceiling
    /// untouched. Takes already-clamped budgets — `build` clamps once per
    /// pack so both limits share one clamped value.
    /// - Parameter budgets: Clamped recall budgets for the turn.
    /// - Returns: Usable per-line cap, never above the fixed ceiling.
    static func effectiveLineLimit(for budgets: RecallBudgets) -> Int {
        min(maxLineChars, budgets.perHitChars)
    }

    /// Total budget for one pack, tightening the ceiling when recall is small.
    ///
    /// A small `maxChars` shrinks starter footing so it never crowds out the
    /// recall block it rides beside; the default budgets leave the fixed
    /// ceiling untouched. Takes already-clamped budgets — `build` clamps
    /// once per pack so both limits share one clamped value.
    /// - Parameter budgets: Clamped recall budgets for the turn.
    /// - Returns: Usable total cap, never above the fixed ceiling.
    static func effectiveTotalLimit(for budgets: RecallBudgets) -> Int {
        min(maxTotalChars, budgets.maxChars)
    }

    /// Builds at most one system message with starter footing.
    /// - Parameters:
    ///   - profile: Live user profile for the `Profile:` line.
    ///   - indexAsOf: Index watermark, nil when the index is disabled, epoch when enabled but empty.
    ///   - goalLine: Optional active goal line for the `Goal:` row.
    ///   - budgets: Live recall budgets bounding pack lines and total chars.
    /// - Returns: A trusted verbatim system message, or nil when every input is empty or disabled.
    public static func build(
        profile: UserProfile,
        indexAsOf: Date?,
        goalLine: String?,
        budgets: RecallBudgets
    ) -> Message? {
        let state: StarterIndexState = if let indexAsOf {
            if indexAsOf.timeIntervalSince1970 > 0 {
                .ready(indexAsOf)
            } else {
                .empty
            }
        } else {
            .disabled
        }
        return build(profile: profile, indexState: state, goalLine: goalLine, budgets: budgets)
    }

    /// Builds at most one system message with starter footing from explicit freshness.
    /// - Parameters:
    ///   - profile: Live user profile for the `Profile:` line.
    ///   - indexState: Freshness distinguishing a missing store from an enabled-but-empty one.
    ///   - goalLine: Optional active goal line for the `Goal:` row.
    ///   - budgets: Live recall budgets bounding pack lines and total chars.
    /// - Returns: A trusted verbatim system message, or nil when every input is empty or disabled.
    public static func build(
        profile: UserProfile,
        indexState: StarterIndexState,
        goalLine: String?,
        budgets: RecallBudgets
    ) -> Message? {
        let clamped = budgets.clamped()
        let lineLimit = effectiveLineLimit(for: clamped)
        let totalLimit = effectiveTotalLimit(for: clamped)
        let name = displayName(from: profile)
        let goal = singleLine(goalLine)
        let hasGoal = goal != nil
        let hasIndex = switch indexState {
        case .disabled: false
        case .empty, .ready: true
        }
        guard name != nil || hasIndex || hasGoal else { return nil }
        let profileValue: String = if let name, !name.isEmpty {
            name
        } else {
            "none"
        }
        let indexValue: String = switch indexState {
        case .disabled:
            "disabled"
        case .empty:
            "empty"
        case let .ready(stamp):
            ISO8601DateFormatter().string(from: stamp)
        }
        var lines = [
            cappedLine("Profile: \(profileValue)", limit: lineLimit),
            cappedLine("Index as of: \(indexValue)", limit: lineLimit)
        ]
        if let goal {
            lines.append(cappedLine("Goal: \(goal)", limit: lineLimit))
        }
        let joined = lines.joined(separator: "\n")
        // Reserve one char so the whole pack stays strictly under `totalLimit`
        // (`< 600` per blueprint) while sharing the single truncation helper.
        return Message(role: .system, content: MemoryEngine.truncateRecallBlock(joined, maxChars: max(1, totalLimit - 1)))
    }

    /// Builds the starter pack from live engine state for one turn.
    /// - Parameters:
    ///   - engine: Memory engine owning the profile plus document index.
    ///   - goalLine: Optional active goal line, nil when no goal store is wired.
    ///   - budgets: Live recall budgets bounding pack lines and total chars.
    /// - Returns: A trusted verbatim system message, or nil when empty and disabled.
    public static func build(
        for engine: MemoryEngine,
        goalLine: String?,
        budgets: RecallBudgets
    ) async -> Message? {
        let profile = await engine.getUserProfile()
        let indexState = await engine.starterIndexState()
        return build(profile: profile, indexState: indexState, goalLine: goalLine, budgets: budgets)
    }

    /// Owner display name from the single-value `name` preference.
    /// - Parameter profile: Live user profile.
    /// - Returns: Trimmed single-line name, or nil when absent.
    static func displayName(from profile: UserProfile) -> String? {
        guard let raw = profile.preferences.last(where: { $0.key.lowercased() == "name" })?.value else {
            return nil
        }
        let collapsed = singleLine(raw)
        guard let collapsed, !collapsed.isEmpty else { return nil }
        return collapsed
    }

    /// Collapses one optional value to trimmed single-line text.
    ///
    /// Single-sourced on the recall line squash so starter names and recall
    /// citations fold newlines and tabs identically instead of drifting.
    /// - Parameter value: Raw value that may carry newlines or tabs.
    /// - Returns: Trimmed single-line text, or nil when blank.
    static func singleLine(_ value: String?) -> String? {
        guard let value else { return nil }
        let collapsed = MemoryEngine.singleLineSquashed(value)
        guard !collapsed.isEmpty else { return nil }
        return collapsed
    }

    /// Caps one pack line below the per-line bound, signaling truncation.
    ///
    /// Single-sourced on `MemoryEngine.truncateRecallBlock` so starter lines
    /// and the recall block share one truncation boundary (including the
    /// tiny-limit edge) and never disagree at the edge. Reserves one char
    /// (`limit - 1`) so a truncated line stays strictly under `limit`
    /// (`< 200` per blueprint) instead of landing exactly on it.
    /// - Parameters:
    ///   - line: Full line including its `Prefix: ` label.
    ///   - limit: Usable per-line cap, already tightened from live budgets.
    /// - Returns: The line when short, otherwise an ellipsis-capped prefix under `limit`.
    static func cappedLine(_ line: String, limit: Int = maxLineChars) -> String {
        MemoryEngine.truncateRecallBlock(line, maxChars: max(1, limit - 1))
    }
}

extension MemoryEngine {
    /// Freshness for starter footing, keeping opt-out distinct from empty.
    ///
    /// Only a missing store reads as opted out; a wired store that fails to
    /// report, holds no documents, or carries an epoch watermark reads as
    /// enabled-but-empty so the pack never misreports an empty index as disabled.
    /// - Returns: Freshness for the pack to render honestly.
    func starterIndexState() async -> StarterIndexState {
        guard let store = docIndexStore else { return .disabled }
        guard let stats = try? await store.stats() else { return .empty }
        guard stats.documents > 0 else { return .empty }
        guard stats.indexAsOf.timeIntervalSince1970 > 0 else { return .empty }
        return .ready(stats.indexAsOf)
    }

    /// Newest index watermark for starter footing, or nil when disabled or empty.
    ///
    /// Compatibility wrapper for callers that still spell freshness as an
    /// optional date; the pack itself renders from the state above so empty
    /// never collapses into disabled.
    /// - Returns: The watermark instant, or nil when the store is missing, unreadable, or holds no documents.
    func starterIndexAsOf() async -> Date? {
        switch await starterIndexState() {
        case .disabled, .empty:
            nil
        case let .ready(stamp):
            stamp
        }
    }
}

// Rune Weaver Core — Always-on starter context for turn footing.

import Foundation

/// Freshness for starter footing, keeping a missing store distinct from an enabled-but-empty one.
public enum StarterIndexState: Sendable, Equatable {
    /// No document store is wired, so index footing stays opted out.
    case disabled
    /// A store is wired but holds no documents or no fresh watermark yet.
    case empty
    /// A store is wired and carries a fresh watermark for the pack to cite.
    case ready(Date)
}

/// Always-on starter footing for every turn: owner name plus index freshness. Trusted verbatim
/// context (never labeled) injected as a second system message beside automatic recall.
public enum RecallStarterPack: Sendable {
    /// Ceiling for any single pack line; live budgets can only tighten it.
    public static let maxLineChars = 200
    /// Ceiling for the whole pack block; live budgets can only tighten it.
    public static let maxTotalChars = 600

    /// Per-line budget for one pack, tightening the ceiling when recall is small.
    static func effectiveLineLimit(for budgets: RecallBudgets) -> Int {
        min(maxLineChars, budgets.perHitChars)
    }

    /// Total budget for one pack, tightening the ceiling when recall is small.
    static func effectiveTotalLimit(for budgets: RecallBudgets) -> Int {
        min(maxTotalChars, budgets.maxChars)
    }

    /// Builds at most one system message with starter footing. profile: Live user
    /// profile for the `Profile:` line.
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

    /// Builds at most one system message with starter footing from explicit freshness. -
    /// Parameters: - profile: Live user profile for the `Profile:` line.
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
        // while sharing the single truncation helper.
        return Message(role: .system, content: MemoryEngine.truncateRecallBlock(joined, maxChars: max(1, totalLimit - 1)))
    }

    /// Builds the starter pack from live engine state for one turn. engine: Memory
    /// engine owning the profile plus document index.
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
    static func singleLine(_ value: String?) -> String? {
        guard let value else { return nil }
        let collapsed = MemoryEngine.singleLineSquashed(value)
        guard !collapsed.isEmpty else { return nil }
        return collapsed
    }

    /// Caps one pack line below the per-line bound, signaling truncation.
    static func cappedLine(_ line: String, limit: Int = maxLineChars) -> String {
        MemoryEngine.truncateRecallBlock(line, maxChars: max(1, limit - 1))
    }
}

extension MemoryEngine {
    /// Freshness for starter footing, keeping opt-out distinct from empty.
    func starterIndexState() async -> StarterIndexState {
        guard let store = docIndexStore else { return .disabled }
        let stats: IndexStats
        do {
            stats = try await store.stats()
        } catch is CancellationError {
            return .empty
        } catch {
            RuneWeaverLog.stores.debug("RecallStarterPack: failed to read store stats: \(error.localizedDescription)")
            return .empty
        }
        guard stats.documents > 0, stats.indexAsOf.timeIntervalSince1970 > 0 else { return .empty }
        return .ready(stats.indexAsOf)
    }

    /// Newest index watermark for starter footing, or nil when disabled or empty.
    func starterIndexAsOf() async -> Date? {
        switch await starterIndexState() {
        case .disabled, .empty:
            nil
        case let .ready(stamp):
            stamp
        }
    }
}

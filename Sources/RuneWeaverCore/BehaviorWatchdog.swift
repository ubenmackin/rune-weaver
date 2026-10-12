// Rune Weaver Core — Trusted-tool anomaly watchdog with a parked-session brake.
//
// Purpose: observe trusted-tool activity and approval outcomes as counts only
// and park every running turn with one inbox card when a rate, denial,
// off-hours, or firewall rule fires, resuming only on explicit owner action.
// Scope: outcome ingestion, the four trailing-window rules, the parked brake
// with its persisted count-only baselines, and the pulse health projection.
// Approval gating, egress supervision, and pulse fusion stay with their owners.
// Architectural role: the counting brake behind the brake contract — it never
// holds arguments, prompts, or model output and never auto-remediates.

import Foundation

/// Anomaly rule identifiers; snake_case wire names shared by cards and logs.
public enum WatchdogRule: String, Sendable, Codable, CaseIterable {
    /// Trailing-hour rate for one tool past the baseline-derived threshold.
    case rateSpike = "rate_spike"
    /// Approval denials in the trailing hour at or above the fixed threshold.
    case denialSpike = "denial_spike"
    /// Trailing-hour activity inside the quiet off-hours window past threshold.
    case offHours = "off_hours"
    /// Egress-supervisor refusals in the trailing hour past threshold.
    case firewallSpike = "firewall_spike"
}

/// Outcome category for one ingested trusted-tool observation.
///
/// Only the category is recorded — never which command ran, what arguments it
/// carried, or any model or prompt text.
public enum WatchdogOutcome: String, Sendable, Codable {
    /// The tool call executed.
    case executed
    /// An approval request was denied.
    case denied
    /// The outbound egress supervisor refused the request.
    case firewallBlocked
}

/// Why the watchdog braked: the fired rule plus the observed-versus-baseline numbers.
public struct BrakeReason: Sendable, Codable, Equatable {
    /// Rule that fired.
    public let rule: WatchdogRule
    /// Tool attributed to the spike, when the fired rule is per-tool.
    public let toolName: String?
    /// Observed count inside the trailing evaluation window.
    public let observed: Int
    /// Reference count the observation is compared against: the learned hourly
    /// average for the rate, off-hours, and firewall rules, and the fixed
    /// per-hour denial threshold for the denial rule.
    public let baseline: Int

    /// Creates a brake reason.
    /// - Parameters:
    ///   - rule: Rule that fired.
    ///   - observed: Observed count inside the trailing evaluation window.
    ///   - baseline: Reference count the observation is compared against.
    ///   - toolName: Attributed tool, when the fired rule is per-tool.
    public init(rule: WatchdogRule, observed: Int, baseline: Int, toolName: String? = nil) {
        self.rule = rule
        self.observed = observed
        self.baseline = baseline
        self.toolName = toolName
    }
}

/// Outcome of one watchdog evaluation pass.
public struct BrakeDecision: Sendable, Equatable {
    /// Rule that fired, or nil when every rule stayed quiet.
    public let rule: WatchdogRule?
    /// Tool attributed to the spike, when the fired rule is per-tool.
    public let toolName: String?
    /// Observed count inside the trailing evaluation window.
    public let observed: Int
    /// Reference count for the evaluation.
    public let baseline: Int
    /// Whether any rule fired.
    public var fired: Bool {
        rule != nil
    }

    /// Reason to hand to ``BehaviorWatchdog/brake(reason:)``, or nil when quiet.
    public var reason: BrakeReason? {
        guard let rule else { return nil }
        return BrakeReason(rule: rule, observed: observed, baseline: baseline, toolName: toolName)
    }

    /// Creates a decision; defaults describe a quiet pass.
    /// - Parameters:
    ///   - rule: Rule that fired, or nil when quiet.
    ///   - observed: Observed count inside the trailing evaluation window.
    ///   - baseline: Reference count for the evaluation.
    ///   - toolName: Attributed tool, when the fired rule is per-tool.
    public init(rule: WatchdogRule? = nil, observed: Int = 0, baseline: Int = 0, toolName: String? = nil) {
        self.rule = rule
        self.observed = observed
        self.baseline = baseline
        self.toolName = toolName
    }
}

/// Watchdog health, shared with the dashboard pulse.
///
/// Red is fail-closed: it clears only on an explicit owner Resume against a
/// fresh passing snapshot, never on a timer.
public enum WatchdogHealth: String, Sendable, Codable {
    /// Every rule is armed and quiet.
    case green
    /// Degraded: baselines are still gestating, so detection is not armed yet.
    case yellow
    /// Fail-closed: the brake is engaged and an inbox card is pending.
    case red
}

/// One session's contribution to the persisted baselines (counts only).
public struct BehaviorSessionBaseline: Sendable, Codable, Equatable {
    /// Session identifier.
    public let id: String
    /// Learned hourly event average for the session.
    public var hourlyAverage: Int
    /// Events observed since the last persist; bounded and reset on persist.
    public var pending: Int

    /// Creates a session baseline entry.
    /// - Parameters:
    ///   - id: Session identifier.
    ///   - hourlyAverage: Learned hourly event average for the session.
    ///   - pending: Events observed since the last persist.
    public init(id: String, hourlyAverage: Int, pending: Int) {
        self.id = id
        self.hourlyAverage = max(hourlyAverage, 0)
        self.pending = min(max(pending, 0), BehaviorWatchdog.maxPendingPerSession)
    }

    private enum CodingKeys: String, CodingKey {
        case id, hourlyAverage, pending
        case hourlyAverageSnake = "hourly_average"
    }

    /// Encodes the canonical camelCase wire shape both key spellings read back.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(hourlyAverage, forKey: .hourlyAverage)
        try container.encode(pending, forKey: .pending)
    }

    /// Decodes leniently so hand-written entries load; negative values clamp to
    /// the fail-closed bound and pending is capped by the watchdog budget.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        let average = try container.decodeIfPresent(Int.self, forKey: .hourlyAverage)
            ?? container.decodeIfPresent(Int.self, forKey: .hourlyAverageSnake) ?? 0
        hourlyAverage = max(average, 0)
        let pendingValue = try container.decodeIfPresent(Int.self, forKey: .pending) ?? 0
        pending = min(max(pendingValue, 0), BehaviorWatchdog.maxPendingPerSession)
    }
}

/// Persisted baselines document (counts only).
///
/// Decoding is deliberately lenient — missing fields default, unknown future
/// versions reject, and both key spellings plus either timestamp shape decode —
/// so an operator-hand-written or older file can never stop the engine from
/// booting. The document never carries a tool argument, prompt body, or model
/// output, only counts.
public struct BehaviorBaselines: Sendable, Codable, Equatable {
    /// Current persisted-schema version.
    public static let currentVersion = 1

    /// Persisted-schema version.
    public var version: Int
    /// Instant the baseline was last learned or folded; nil for a fresh boot.
    public var learnedAt: Date?
    /// Effective hourly event average across the tracked span.
    public var hourlyAverage: Int
    /// Per-session contributions, bounded to the watchdog's session cap.
    public var sessions: [BehaviorSessionBaseline]

    /// Creates a baselines document.
    /// - Parameters:
    ///   - version: Persisted-schema version.
    ///   - learnedAt: Instant the baseline was last learned or folded.
    ///   - hourlyAverage: Effective hourly event average.
    ///   - sessions: Per-session contributions.
    public init(
        version: Int = BehaviorBaselines.currentVersion,
        learnedAt: Date? = nil,
        hourlyAverage: Int = 0,
        sessions: [BehaviorSessionBaseline] = []
    ) {
        self.version = version
        self.learnedAt = learnedAt
        self.hourlyAverage = max(hourlyAverage, 0)
        self.sessions = sessions
    }

    private enum CodingKeys: String, CodingKey {
        case version, sessions, learnedAt, hourlyAverage
        case learnedAtSnake = "learned_at"
        case hourlyAverageSnake = "hourly_average"
    }

    /// Encodes the canonical camelCase wire shape both key spellings read back.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encodeIfPresent(learnedAt, forKey: .learnedAt)
        try container.encode(hourlyAverage, forKey: .hourlyAverage)
        try container.encode(sessions, forKey: .sessions)
    }

    /// Decodes a timestamp written as deferredToDate seconds or ISO-8601 text.
    private static func decodeDate(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys
    ) -> Date? {
        if let seconds = try? container.decodeIfPresent(Double.self, forKey: key) {
            return Date(timeIntervalSinceReferenceDate: seconds)
        }
        if let text = try? container.decodeIfPresent(String.self, forKey: key) {
            return ISO8601DateFormatter().date(from: text)
        }
        return nil
    }

    /// Decodes leniently: missing fields default, both key spellings and either
    /// timestamp shape load, and the session list is clamped to the watchdog
    /// session cap so an over-long document cannot outgrow the budget.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        learnedAt = Self.decodeDate(container, .learnedAt) ?? Self.decodeDate(container, .learnedAtSnake)
        let average = try container.decodeIfPresent(Int.self, forKey: .hourlyAverage)
            ?? container.decodeIfPresent(Int.self, forKey: .hourlyAverageSnake) ?? 0
        hourlyAverage = max(average, 0)
        let decoded = try container.decodeIfPresent([BehaviorSessionBaseline].self, forKey: .sessions) ?? []
        sessions = Array(decoded.prefix(BehaviorWatchdog.maxTrackedSessions))
    }
}

/// Seam the brake drives to park every running turn.
///
/// The server's active-turn tracker is the production owner; Core names the
/// seam so the watchdog never depends on a server-layer type.
public protocol TurnParking: Sendable {
    /// Session identifiers of every running turn.
    func runningSessionIDs() async -> [UUID]
    /// Cancels the running turn for one session.
    /// - Parameter sessionID: Session whose turn should stop.
    /// - Returns: True when a running turn was cancelled.
    @discardableResult
    func cancel(sessionID: UUID) async -> Bool
}

/// Live counters for one session (counts only).
private struct SessionCounters {
    /// First observation instant.
    var firstSeen: Date
    /// Last observation instant.
    var lastTouched: Date
    /// Total observations.
    var total = 0
    /// Observations since the last persist, bounded by the pending cap.
    var pending = 0
}

/// One minute of trusted-tool counts (counts only).
private struct MinuteCounts {
    /// Executed observations.
    var executed = 0
    /// Denied observations.
    var denied = 0
    /// Egress-refused observations.
    var firewallBlocked = 0

    /// Adds one observation of the given outcome category.
    mutating func record(_ outcome: WatchdogOutcome) {
        switch outcome {
        case .executed:
            executed += 1
        case .denied:
            denied += 1
        case .firewallBlocked:
            firewallBlocked += 1
        }
    }
}

/// Numbers-only card payload filed inside the brake request's arguments.
private struct BrakeCardPayload: Encodable {
    /// Rule that fired.
    let rule: WatchdogRule
    /// Attributed tool, when the fired rule is per-tool.
    let tool: String?
    /// Observed count inside the trailing evaluation window.
    let observed: Int
    /// Reference count the observation is compared against.
    let baseline: Int
    /// Running turns parked by the brake.
    let parkedSessions: Int
    /// Reference-date seconds the brake engaged, so clients decode without
    /// sharing a date strategy with the engine.
    let firedAt: Double
}

/// Trusted-tool anomaly watchdog.
///
/// The actor owns every piece of watchdog state: live per-session counters, the
/// trailing window of minute buckets, the learned baseline, and the brake flag.
/// Baselines load at construction from the persisted JSON sidecar so serve boots
/// resume armed instead of restarting the 14-day gestation, and every
/// evaluation reads live state, so a brake engages without a restart.
public actor BehaviorWatchdog {
    /// Quiet-learning gestation; the watchdog stays silent until it elapses.
    public static let gestationSeconds: TimeInterval = 14 * 24 * 60 * 60
    /// Trailing evaluation window shared by every rate rule.
    public static let trailingWindowSeconds: TimeInterval = 3600
    /// Minute buckets retained for the trailing window; older buckets fold into
    /// the baseline when their hour completes and drop, so memory stays bounded.
    public static let retainedMinuteBuckets = 120
    /// Rate-rule multiplier applied to the baseline hourly average.
    public static let rateMultiplier = 4
    /// Rate-rule floor so a near-zero baseline still fires on a real burst.
    public static let rateFloor = 10
    /// Denials per trailing hour that fire the denial rule, baseline-independent.
    public static let denialThreshold = 3
    /// Inclusive start hour of the quiet off-hours window, local time.
    public static let offHoursStartHour = 0
    /// Exclusive end hour of the quiet off-hours window, local time.
    public static let offHoursEndHour = 5
    /// Maximum tracked sessions, in memory and in the persisted baselines.
    public static let maxTrackedSessions = 500
    /// Maximum pending (unpersisted) events retained per session.
    public static let maxPendingPerSession = 20
    /// Maximum baseline history imported from disk, in days, so a baseline
    /// learned long ago stops dominating the live average.
    public static let maxImportedBaselineDays = 28
    /// Tool name carried by the filed brake card.
    public static let brakeCardToolName = "behavior.brake"
    /// Default baselines path, beside the other durable JSON stores.
    public static let defaultBaselinesPath = "~/.runeweaver/behavior/baselines.json"

    private let approvalQueue: ApprovalQueue
    private let steeringQueue: SteeringQueue
    private let turnParking: any TurnParking
    private let baselinesPath: String
    private let now: @Sendable () -> Date

    /// Live session counters, oldest-touched eviction at the session cap.
    private var sessions: [UUID: SessionCounters] = [:]
    /// Session touch order, oldest first.
    private var sessionOrder: [UUID] = []
    /// Retained minute buckets keyed by truncated minute.
    private var minutes: [Date: MinuteCounts] = [:]
    /// Per-tool executed counts inside each retained minute bucket.
    private var toolMinutes: [Date: [String: Int]] = [:]
    /// Events folded into the baseline from completed hours plus imported history.
    private var foldedEvents = 0
    /// Hours with at least one event folded into the baseline, plus import.
    private var foldedActiveHours = 0
    /// Last hour index folded into the baseline, nil before the first fold.
    private var lastFoldedHour: Int?
    /// First live observation instant, nil before any ingest.
    private var firstSeen: Date?
    /// Whether the brake is currently engaged.
    private var braking = false
    /// Card filed by the engaged brake, nil while quiet.
    private var activeCard: PermissionRequest?
    /// Last loaded or persisted document.
    private var baselines: BehaviorBaselines
    /// Hourly average as of the last persist, for the changed comparison.
    private var persistedAverage = 0
    /// Event total as of the last persist, for the changed comparison.
    private var persistedTotal = 0

    /// Creates a watchdog, loading persisted baselines at boot.
    /// - Parameters:
    ///   - approvalQueue: Inbox the brake card files into.
    ///   - steeringQueue: Steering the brake clears for every parked session.
    ///   - turnParking: Tracker the brake parks every running turn through.
    ///   - baselinesPath: JSON sidecar path; `~` expands on read and write.
    ///   - now: Clock seam, injectable for deterministic evaluation.
    public init(
        approvalQueue: ApprovalQueue,
        steeringQueue: SteeringQueue,
        turnParking: any TurnParking,
        baselinesPath: String = BehaviorWatchdog.defaultBaselinesPath,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.approvalQueue = approvalQueue
        self.steeringQueue = steeringQueue
        self.turnParking = turnParking
        self.baselinesPath = baselinesPath
        self.now = now
        let loaded = Self.readBaselines(path: baselinesPath)
        self.baselines = loaded
        let imported = Self.importedHistory(average: loaded.hourlyAverage, learnedAt: loaded.learnedAt, now: now())
        self.foldedEvents = imported.events
        self.foldedActiveHours = imported.hours
        self.persistedAverage = loaded.hourlyAverage
        self.persistedTotal = imported.events + loaded.sessions.reduce(0) { $0 + $1.pending }
    }

    /// Records one trusted-tool observation as a count.
    ///
    /// Only the tool name, session, and outcome category are retained — never
    /// arguments, prompt bodies, or model output — so neither the live state
    /// nor the persisted baselines can ever hold content.
    /// - Parameters:
    ///   - toolName: Tool that produced the observation.
    ///   - sessionID: Session the observation belongs to.
    ///   - outcome: Outcome category; defaults to a plain execution.
    public func ingest(toolName: String, sessionID: UUID, outcome: WatchdogOutcome = .executed) {
        let now = self.now()
        foldCompletedHours(now: now)
        let minute = Self.minuteKey(now)
        var bucket = minutes[minute] ?? MinuteCounts()
        bucket.record(outcome)
        minutes[minute] = bucket
        if outcome == .executed {
            var toolCounts = toolMinutes[minute] ?? [:]
            toolCounts[toolName, default: 0] += 1
            toolMinutes[minute] = toolCounts
        }
        pruneBuckets(now: now)

        var counters = sessions[sessionID] ?? SessionCounters(firstSeen: now, lastTouched: now)
        counters.total += 1
        if counters.pending < Self.maxPendingPerSession {
            counters.pending += 1
        }
        counters.lastTouched = now
        sessions[sessionID] = counters
        touchSession(sessionID)
        evictSessionsIfNeeded(preferring: sessionID)
        if firstSeen == nil {
            firstSeen = now
        }
    }

    /// Evaluates every rule against the live trailing window and the learned
    /// baseline, braking automatically when a rule fires.
    ///
    /// Silent during gestation: with no armed baseline there is nothing to
    /// compare against, so no rule fires and no card files. When a rule fires
    /// the returned decision still carries the numbers, and the brake it
    /// engages is idempotent, so a repeated evaluation inside the same anomaly
    /// keeps the original card instead of flooding the inbox.
    /// - Returns: The decision, carrying the observed-versus-baseline numbers.
    public func evaluate() async -> BrakeDecision {
        let now = self.now()
        foldCompletedHours(now: now)
        pruneBuckets(now: now)
        guard isArmed(now: now) else {
            return BrakeDecision()
        }
        guard let reason = detect(now: now) else {
            return BrakeDecision()
        }
        await brake(reason: reason)
        return BrakeDecision(rule: reason.rule, observed: reason.observed, baseline: reason.baseline, toolName: reason.toolName)
    }

    /// Parks every running turn, clears their steering, and files the inbox card.
    ///
    /// Idempotent while the brake is engaged: a repeated brake inside the same
    /// anomaly returns the original card and re-parks nothing. The watchdog
    /// never auto-remediates and never approves — a denial (keep paused) leaves
    /// every turn parked exactly as the owner left it, and clearing the brake
    /// is an explicit owner Resume.
    /// - Parameter reason: Fired rule with the observed-versus-baseline numbers.
    /// - Returns: The filed card, or the card already filed while engaged.
    @discardableResult
    public func brake(reason: BrakeReason) async -> PermissionRequest? {
        if braking {
            return activeCard
        }
        braking = true
        var parked = 0
        for sessionID in await turnParking.runningSessionIDs() {
            _ = await turnParking.cancel(sessionID: sessionID)
            await steeringQueue.clear(sessionID: sessionID)
            parked += 1
        }
        let card = await approvalQueue.enqueue(
            toolName: Self.brakeCardToolName,
            description: Self.cardDescription(reason: reason, parkedSessions: parked),
            input: Self.cardInput(reason: reason, parkedSessions: parked, firedAt: now())
        )
        activeCard = card
        RuneWeaverLog.tools.info(
            "BehaviorWatchdog: brake engaged rule=\(reason.rule.rawValue) observed=\(reason.observed) baseline=\(reason.baseline) parked=\(parked)"
        )
        return card
    }

    /// Clears the brake after an explicit owner Resume.
    ///
    /// The trailing counters reset with it, so the resumed hour starts a fresh
    /// snapshot and the just-observed spike cannot immediately re-fire. The
    /// brake never clears on a timer.
    public func resume() {
        guard braking else { return }
        braking = false
        activeCard = nil
        minutes.removeAll()
        toolMinutes.removeAll()
    }

    /// Live health for the dashboard pulse.
    ///
    /// Yellow while baselines gestate (degraded: detection is not armed, with
    /// the remaining gestation disclosed through the baselines snapshot), red
    /// only while the brake is engaged with an inbox card pending. Red clears
    /// on Resume against a fresh passing snapshot, never on a timer.
    /// - Returns: Current watchdog health.
    public func health() -> WatchdogHealth {
        if braking {
            return .red
        }
        return isArmed(now: now()) ? .green : .yellow
    }

    /// Whether the brake is currently engaged.
    /// - Returns: True while every running turn is parked.
    public func isBraking() -> Bool {
        braking
    }

    /// Card filed by the engaged brake.
    /// - Returns: The filed card, or nil while quiet.
    public func activeBrakeCard() -> PermissionRequest? {
        activeCard
    }

    /// Live baselines view: the current computed average, the learned instant,
    /// and per-session contributions (counts only).
    /// - Returns: Snapshot of the baselines as learned so far.
    public func baselinesSnapshot() -> BehaviorBaselines {
        let entries = sessions
            .map { BehaviorSessionBaseline(id: $0.key.uuidString, hourlyAverage: sessionAverage($0.value), pending: $0.value.pending) }
            .sorted { $0.id < $1.id }
        return BehaviorBaselines(
            version: BehaviorBaselines.currentVersion,
            learnedAt: baselines.learnedAt ?? firstSeen,
            hourlyAverage: baselineAverage(),
            sessions: entries
        )
    }

    /// Whether live counts diverged from the last persisted baseline.
    ///
    /// Compares the live event total and the computed hourly average against
    /// what was last persisted, so a dashboard can disclose pending learning
    /// without recomputing it.
    /// - Returns: True when counts moved past the persisted baseline.
    public func baselineChanged() -> Bool {
        if liveTotal() != persistedTotal {
            return true
        }
        return baselineAverage() != persistedAverage
    }

    /// Persists the baselines sidecar atomically.
    ///
    /// Writes counts only — the document never carries a tool argument, prompt
    /// body, or model output — and folds every session's pending events into
    /// the persisted baseline so ``baselineChanged()`` reports false afterwards.
    public func persistBaselines() throws {
        let observedKeys = Array(sessions.keys)
        for key in observedKeys {
            sessions[key]?.pending = 0
        }
        let snapshot = baselinesSnapshot()
        let data = try JSONEncoder().encode(snapshot)
        let expanded = (baselinesPath as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        baselines = snapshot
        persistedAverage = snapshot.hourlyAverage
        persistedTotal = liveTotal()
    }

    /// Number of sessions currently tracked, bounded by the session cap.
    /// - Returns: Tracked session count.
    public func sessionCount() -> Int {
        sessions.count
    }

    /// Pending (unpersisted) observations retained for one session.
    /// - Parameter sessionID: Session to read.
    /// - Returns: Pending count, bounded by the pending cap.
    public func pendingCount(sessionID: UUID) -> Int {
        sessions[sessionID]?.pending ?? 0
    }
}

// MARK: - Rule Evaluation Machinery

extension BehaviorWatchdog {
    /// First rule that fires against the trailing window, in evaluation order.
    private func detect(now: Date) -> BrakeReason? {
        let windowStart = now.addingTimeInterval(-BehaviorWatchdog.trailingWindowSeconds)
        var denied = 0
        var firewallBlocked = 0
        var offHoursExecuted = 0
        var perTool: [String: Int] = [:]
        for (minute, counts) in minutes {
            guard minute > windowStart else { continue }
            denied += counts.denied
            firewallBlocked += counts.firewallBlocked
            if BehaviorWatchdog.isOffHours(minute) {
                offHoursExecuted += counts.executed
            }
            for (tool, count) in toolMinutes[minute] ?? [:] {
                perTool[tool, default: 0] += count
            }
        }
        let baseline = baselineAverage()
        // One shared rate math for the per-tool, off-hours, and firewall rules:
        // a burst past four times the quiet baseline, floored so a near-zero
        // baseline still fires on a real spike.
        let threshold = max(BehaviorWatchdog.rateMultiplier * baseline, BehaviorWatchdog.rateFloor)
        let spiking = perTool
            .filter { $0.value > threshold }
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .first
        if let spiking {
            return BrakeReason(rule: .rateSpike, observed: spiking.value, baseline: baseline, toolName: spiking.key)
        }
        if denied >= BehaviorWatchdog.denialThreshold {
            return BrakeReason(rule: .denialSpike, observed: denied, baseline: BehaviorWatchdog.denialThreshold)
        }
        if offHoursExecuted > threshold {
            return BrakeReason(rule: .offHours, observed: offHoursExecuted, baseline: baseline)
        }
        if firewallBlocked > threshold {
            return BrakeReason(rule: .firewallSpike, observed: firewallBlocked, baseline: baseline)
        }
        return nil
    }

    /// Whether detection is armed.
    ///
    /// A persisted baseline learned past the gestation window arms immediately,
    /// so a serve boot that loads mature counts resumes armed instead of
    /// restarting the quiet window. A document carrying counts without a
    /// learning timestamp arms too: there is no recorded window to wait out, and
    /// staying silent forever on seeded counts would read as a deliberate
    /// disarm. A document that recorded a still-gestating window keeps waiting
    /// out that window, and a fresh install with no document at all arms only
    /// once live observations span the whole gestation.
    private func isArmed(now: Date) -> Bool {
        if let learnedAt = baselines.learnedAt {
            return now.timeIntervalSince(learnedAt) >= BehaviorWatchdog.gestationSeconds
        }
        if baselineAverage() > 0 || !baselines.sessions.isEmpty {
            return true
        }
        guard let firstSeen else { return false }
        return now.timeIntervalSince(firstSeen) >= BehaviorWatchdog.gestationSeconds
    }

    /// Folds completed hours into the baseline and advances the fold mark.
    ///
    /// The in-progress hour never folds, so a burst still in flight cannot
    /// raise the baseline it is being measured against. Hours with no retained
    /// bucket — idle spans, or a clock jump — fold zero events, which limits
    /// their influence instead of freezing a stale average forever.
    private func foldCompletedHours(now: Date) {
        let currentHour = BehaviorWatchdog.hourIndex(now)
        guard let last = lastFoldedHour else {
            lastFoldedHour = currentHour
            return
        }
        guard currentHour > last else { return }
        var perHour: [Int: Int] = [:]
        for (minute, counts) in minutes {
            let hour = BehaviorWatchdog.hourIndex(minute)
            if hour >= last, hour < currentHour {
                perHour[hour, default: 0] += counts.executed + counts.denied + counts.firewallBlocked
            }
        }
        for hour in last ... (currentHour - 1) {
            let events = perHour[hour] ?? 0
            foldedEvents += events
            if events > 0 {
                foldedActiveHours += 1
            }
        }
        lastFoldedHour = currentHour
    }

    /// Drops buckets past the retained window so memory stays bounded.
    private func pruneBuckets(now: Date) {
        guard minutes.count > BehaviorWatchdog.retainedMinuteBuckets else { return }
        let cutoff = now.addingTimeInterval(-Double(BehaviorWatchdog.retainedMinuteBuckets) * 60)
        let stale = minutes.keys.filter { $0 <= cutoff }
        for key in stale {
            minutes.removeValue(forKey: key)
            toolMinutes.removeValue(forKey: key)
        }
    }

    /// Moves a session to the most-recent position for eviction ordering.
    private func touchSession(_ sessionID: UUID) {
        if let index = sessionOrder.firstIndex(of: sessionID) {
            sessionOrder.remove(at: index)
        }
        sessionOrder.append(sessionID)
    }

    /// Evicts least-recently-touched sessions past the session cap.
    private func evictSessionsIfNeeded(preferring sessionID: UUID) {
        while sessions.count > BehaviorWatchdog.maxTrackedSessions {
            let victim = sessionOrder.first(where: { $0 != sessionID })
                ?? sessions.keys.first(where: { $0 != sessionID })
            guard let victim else { break }
            sessions.removeValue(forKey: victim)
            sessionOrder.removeAll(where: { $0 == victim })
        }
    }

    /// Learned hourly average: folded events over the hours that had any.
    private func baselineAverage() -> Int {
        guard foldedActiveHours > 0 else { return 0 }
        return Int((Double(foldedEvents) / Double(foldedActiveHours)).rounded())
    }

    /// Live event total: imported history plus every live observation.
    private func liveTotal() -> Int {
        foldedEvents + sessions.values.reduce(0) { $0 + $1.total }
    }

    /// Average hourly events for one session over its observed span.
    private func sessionAverage(_ counters: SessionCounters) -> Int {
        let hours = max(counters.lastTouched.timeIntervalSince(counters.firstSeen) / 3600, 1)
        return Int((Double(counters.total) / hours).rounded())
    }
}

// MARK: - Pure Helpers

extension BehaviorWatchdog {
    /// Floor-divided hour index for an instant, stable across time zones.
    fileprivate static func hourIndex(_ date: Date) -> Int {
        Int((date.timeIntervalSince1970 / 3600).rounded(.down))
    }

    /// Truncated-to-the-minute instant used as a bucket key.
    fileprivate static func minuteKey(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded(.down) * 60)
    }

    /// Whether the instant falls inside the quiet off-hours window, local time.
    fileprivate static func isOffHours(_ date: Date) -> Bool {
        let hour = Calendar.current.component(.hour, from: date)
        return hour >= BehaviorWatchdog.offHoursStartHour && hour < BehaviorWatchdog.offHoursEndHour
    }

    /// Seeds the baseline fold from a loaded document.
    ///
    /// The imported span is capped so a baseline learned months ago stops
    /// dominating the live average; a document without a learned instant
    /// contributes exactly one hour of history, preserving its average until
    /// live folds take over.
    fileprivate static func importedHistory(average: Int, learnedAt: Date?, now: Date) -> (events: Int, hours: Int) {
        guard average > 0 else { return (0, 0) }
        let spanHours: Double = if let learnedAt {
            min(now.timeIntervalSince(learnedAt) / 3600, Double(BehaviorWatchdog.maxImportedBaselineDays * 24))
        } else {
            1
        }
        let hours = max(Int(spanHours.rounded(.down)), 1)
        return (average * hours, hours)
    }

    /// Reads the persisted baselines, failing closed to a fresh silent document.
    fileprivate static func readBaselines(path: String) -> BehaviorBaselines {
        let expanded = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            return BehaviorBaselines()
        }
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: expanded))
        } catch {
            RuneWeaverLog.stores.warning("BehaviorWatchdog: unreadable baselines at '\(expanded)': \(error.localizedDescription)")
            return BehaviorBaselines()
        }
        do {
            let document = try JSONDecoder().decode(BehaviorBaselines.self, from: data)
            guard document.version <= BehaviorBaselines.currentVersion else {
                RuneWeaverLog.stores.warning("BehaviorWatchdog: ignoring baselines version \(document.version) at '\(expanded)'")
                return BehaviorBaselines()
            }
            return document
        } catch {
            RuneWeaverLog.stores.warning("BehaviorWatchdog: undecodable baselines at '\(expanded)': \(error.localizedDescription)")
            return BehaviorBaselines()
        }
    }

    /// Card copy: title, rule, observed versus baseline, and the owner actions.
    fileprivate static func cardDescription(reason: BrakeReason, parkedSessions: Int) -> String {
        let subject = reason.toolName.map { "\($0) activity" } ?? "Trusted-tool activity"
        return "Brake — \(reason.rule.rawValue): \(subject) reached \(reason.observed) in the last hour versus a baseline of \(reason.baseline). "
            + "\(parkedSessions) running turn(s) parked and steering cleared. Resume to release them, or keep them paused."
    }

    /// Card payload: rule, numbers, parked count, and timestamp — counts only.
    fileprivate static func cardInput(reason: BrakeReason, parkedSessions: Int, firedAt: Date) -> ToolInput {
        let payload = BrakeCardPayload(
            rule: reason.rule,
            tool: reason.toolName,
            observed: reason.observed,
            baseline: reason.baseline,
            parkedSessions: parkedSessions,
            firedAt: firedAt.timeIntervalSinceReferenceDate
        )
        let data = (try? JSONEncoder().encode(payload)) ?? Data("{}".utf8)
        return ToolInput(
            toolName: BehaviorWatchdog.brakeCardToolName,
            argumentsJSON: String(data: data, encoding: .utf8) ?? "{}"
        )
    }
}

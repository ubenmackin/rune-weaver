// Rune Weaver Core — Verified system-pulse health snapshot.

import CryptoKit
import Foundation

// MARK: - Pulse Status

/// Closed health verdict for the verified system pulse.
public enum HealthPulseStatus: String, Sendable, Codable, Equatable {
    /// Every recorded verifier passes.
    case green
    /// Degraded with reasons behind a disclosure.
    case yellow
    /// Fail-closed, parked until a fresh passing verification.
    case red
}

/// Collapsed verdict over the recorded subsystem probes.
public enum HealthProbeVerdict: String, Sendable, Codable, Equatable {
    /// Every recorded probe passed.
    case pass
    /// A non-critical probe failed.
    case degraded
    /// A fail-closed probe failed.
    case fail
}

// MARK: - Probe Outcomes

/// One subsystem probe completion recorded into the pulse. Search reachability is intentionally
/// excluded; it rides TopNav, never the pulse.
public struct HealthProbeOutcome: Sendable, Equatable, Codable {
    /// Stable verifier name (for example `"suite"`).
    public let name: String
    /// Whether the probe passed.
    public let passed: Bool
    /// Whether a failure here fails closed instead of merely degrading.
    public let failClosed: Bool
    /// Bounded failure detail for the disclosure, nil when passing or silent.
    public let detail: String?

    /// Creates a probe outcome, normalizing the name and detail. name: Stable
    /// verifier name.
    public init(name: String, passed: Bool, failClosed: Bool = false, detail: String? = nil) {
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.passed = passed
        self.failClosed = failClosed
        self.detail = HealthSnapshotValue.normalizedDetail(detail)
    }
}

// MARK: - Sovereign Ceremony

/// Enclave-signed checkpoint vote attesting a ledger head.
public struct SovereignCheckpointVote: Sendable, Equatable, Codable {
    /// Ledger head the vote attests.
    public let tip: String
    /// Enclave signature bytes, hex encoded.
    public let signature: String
    /// Enclave signing key identity.
    public let signer: String

    /// Creates a checkpoint vote, trimming each field. tip: Ledger head the vote
    /// attests.
    public init(tip: String, signature: String, signer: String) {
        self.tip = tip.trimmingCharacters(in: .whitespacesAndNewlines)
        self.signature = signature.trimmingCharacters(in: .whitespacesAndNewlines)
        self.signer = signer.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether this vote attests the given normalized ledger head.
    /// - Parameter tip: Normalized head to check against.
    public func attests(tip: String) -> Bool {
        guard HealthSnapshotValue.normalizedTip(self.tip) == tip else { return false }
        return !signature.isEmpty && !signer.isEmpty
    }
}

/// One recorded sovereign verification ceremony.
public struct SovereignCeremony: Sendable, Equatable, Codable {
    /// Observed primary ledger head, nil when none was presented.
    public let primaryTip: String?
    /// Attested sovereign copy head, nil when none was presented.
    public let sovereignTip: String?
    /// Checkpoint vote presented with the ceremony, if any.
    public let vote: SovereignCheckpointVote?
    /// Parity outcome, nil when the ceremony carried nothing to compare.
    public let matched: Bool?
    /// How the signed vote resolved a disagreement, nil when unadjudicated.
    public let decision: SovereignDecision?
    /// When the ceremony was recorded.
    public let recordedAt: Date

    /// Creates a ceremony record. primaryTip: Observed primary ledger head.
    public init(
        primaryTip: String?,
        sovereignTip: String?,
        vote: SovereignCheckpointVote?,
        matched: Bool?,
        decision: SovereignDecision? = nil,
        recordedAt: Date = Date()
    ) {
        self.primaryTip = primaryTip
        self.sovereignTip = sovereignTip
        self.vote = vote
        self.matched = matched
        self.decision = decision
        self.recordedAt = recordedAt
    }
}

// MARK: - Snapshot Value

/// Verified system-pulse value served behind `GET /health`.
public struct HealthSnapshotValue: Sendable, Equatable, Codable {
    /// Maximum accepted tip/hash length: 64 hex chars for a SHA-256 digest
    /// with headroom to 128 for longer digests. Longer input is rejected,
    /// never truncated, because truncating a digest changes its identity.
    public static let maxTipLength = 128
    /// Maximum served reasons, keeping the disclosure bounded.
    public static let maxDegradedReasons = 8
    /// Maximum length per reason; longer text truncates since the signal is
    /// display copy, unlike a digest whose identity must stay exact.
    public static let maxReasonLength = 160
    /// Maximum served info notes, same bound as degraded reasons.
    public static let maxInfoNotes = 8
    /// Maximum length per info note, same bound as degraded reasons.
    public static let maxInfoNoteLength = 160

    /// Closed pulse status.
    public let status: HealthPulseStatus
    /// Observed primary ledger head digest, nil until a ceremony presents one.
    public let ledgerTip: String?
    /// Last explicit ledger verification instant, nil until one is stamped.
    public let ledgerVerifiedAt: Date?
    /// SHA-256 of the canonical verified policy TOML, nil while unverified.
    public let policyHash: String?
    /// Whether the live policy verifies against the formal invariants.
    public let policyVerified: Bool
    /// Collapsed probe verdict, nil before any probe reports.
    public let probeVerdict: HealthProbeVerdict?
    /// Bounded backing reasons for a non-green status.
    public let degradedReasons: [String]
    /// Bounded info notes that never move the dot.
    public let infoNotes: [String]

    /// Creates a snapshot value. status: Closed pulse status.
    public init(
        status: HealthPulseStatus,
        ledgerTip: String? = nil,
        ledgerVerifiedAt: Date? = nil,
        policyHash: String? = nil,
        policyVerified: Bool = false,
        probeVerdict: HealthProbeVerdict? = nil,
        degradedReasons: [String] = [],
        infoNotes: [String] = []
    ) {
        self.status = status
        self.ledgerTip = Self.normalizedTip(ledgerTip)
        self.ledgerVerifiedAt = ledgerVerifiedAt
        self.policyHash = Self.normalizedTip(policyHash)
        self.policyVerified = policyVerified
        self.probeVerdict = probeVerdict
        self.degradedReasons = Self.normalizedReasons(degradedReasons)
        self.infoNotes = Self.normalizedInfoNotes(infoNotes)
    }

    private enum CodingKeys: String, CodingKey {
        case status
        case ledgerTip
        case ledgerVerifiedAt
        case policyHash
        case policyVerified
        case probeVerdict
        case degradedReasons
        case infoNotes
    }

    /// Decodes tolerantly so values persisted before info notes still parse.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(HealthPulseStatus.self, forKey: .status)
        ledgerTip = try container.decodeIfPresent(String.self, forKey: .ledgerTip)
        ledgerVerifiedAt = try container.decodeIfPresent(Date.self, forKey: .ledgerVerifiedAt)
        policyHash = try container.decodeIfPresent(String.self, forKey: .policyHash)
        policyVerified = try container.decodeIfPresent(Bool.self, forKey: .policyVerified) ?? false
        probeVerdict = try container.decodeIfPresent(HealthProbeVerdict.self, forKey: .probeVerdict)
        degradedReasons = try Self.normalizedReasons(container.decodeIfPresent([String].self, forKey: .degradedReasons))
        infoNotes = try Self.normalizedInfoNotes(container.decodeIfPresent([String].self, forKey: .infoNotes))
    }

    /// Encodes every field so deep equality covers info notes.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(ledgerTip, forKey: .ledgerTip)
        try container.encodeIfPresent(ledgerVerifiedAt, forKey: .ledgerVerifiedAt)
        try container.encodeIfPresent(policyHash, forKey: .policyHash)
        try container.encode(policyVerified, forKey: .policyVerified)
        try container.encodeIfPresent(probeVerdict, forKey: .probeVerdict)
        try container.encode(degradedReasons, forKey: .degradedReasons)
        try container.encode(infoNotes, forKey: .infoNotes)
    }

    /// Normalizes a tip or hash digest: trims, lowercases, and accepts hex of up to `maxTipLength`.
    /// Blank, non-hex, or over-long input is rejected to nil instead of stored, so empty text never
    /// becomes a tip.
    public static func normalizedTip(_ value: String?) -> String? {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty, trimmed.count <= maxTipLength else { return nil }
        guard trimmed.allSatisfy(\.isHexDigit) else { return nil }
        return trimmed
    }

    /// Normalizes one reason fragment: trims and caps at `maxReasonLength`. Blank degrades to nil
    /// so empty text never becomes a reason.
    public static func normalizedDetail(_ value: String?) -> String? {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maxReasonLength))
    }

    /// Normalizes a reason list: drops blanks, caps each entry, keeps the first
    /// `maxDegradedReasons` so the disclosure stays bounded.
    /// - Parameter values: Raw reasons.
    public static func normalizedReasons(_ values: [String]?) -> [String] {
        guard let values else { return [] }
        var normalized: [String] = []
        for value in values {
            guard let detail = normalizedDetail(value) else { continue }
            normalized.append(detail)
            if normalized.count >= maxDegradedReasons {
                break
            }
        }
        return normalized
    }

    /// Normalizes an info list with the same 8-item 160-char bounds.
    /// - Parameter values: Raw info notes.
    /// - Returns: Bounded notes, empty when none survive.
    public static func normalizedInfoNotes(_ values: [String]?) -> [String] {
        guard let values else { return [] }
        var normalized: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            normalized.append(String(trimmed.prefix(maxInfoNoteLength)))
            if normalized.count >= maxInfoNotes {
                break
            }
        }
        return normalized
    }

    /// Normalizes a collapsed probe verdict against its closed vocabulary. Drifted values degrade
    /// to nil instead of failing the probe.
    public static func normalizedProbeVerdict(_ value: String?) -> HealthProbeVerdict? {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return HealthProbeVerdict(rawValue: trimmed)
    }
}

// MARK: - Snapshot Actor

/// Actor-backed verified system-pulse snapshot.
public actor SystemHealthSnapshot {
    /// Reason served while a sovereign mismatch parks the pulse red. Names
    /// the gate and the remedy without tip material, since reasons travel on
    /// unauthenticated projections that must not carry digests.
    private static let sovereignParkedReason =
        "Ledger and sovereign copy disagree; fail-closed and parked until an approved re-verification passes."
    /// Reason served while the behavior brake parks the pulse red.
    private static let watchdogBrakeReason =
        "Trusted-tool anomaly brake is engaged; turns are parked until the brake card is resumed."

    /// Builds the gestation countdown info note, clamped to the 1...14 bound.
    private static func gestationNote(days: Int) -> String {
        let clamped = min(max(days, 1), 14)
        return "Behavior baseline is still learning; anomaly detection arms in ~\(clamped) days."
    }

    /// Live declarative policy store read on every snapshot, or nil when the
    /// snapshot has no policy posture to report. A nil store contributes no
    /// signal either way: unverifiable here means unknown, not failed.
    private let policyStore: PolicyStore?
    /// Last probe outcome per verifier name.
    private var probes: [String: HealthProbeOutcome] = [:]
    /// Last recorded sovereign ceremony, if any.
    private var ceremony: SovereignCeremony?
    /// Latched sovereign mismatch: set by a failed ceremony, cleared only
    /// by a freshly recorded passing one.
    private var parkedMismatch = false
    /// Last recorded watchdog health, nil before the first evaluation.
    /// Absence constrains nothing: the brake narrows the pulse only once it
    /// reports, mirroring every other verifier family.
    private var watchdogHealth: WatchdogHealth?
    /// Gestation countdown days, nil when armed or braking. Set alongside
    /// the watchdog health on the serving cadence; cleared when armed so an
    /// armed quiet pulse carries no countdown.
    private var watchdogGestationDays: Int?
    /// Observed primary ledger head from the last ceremony that presented one.
    private var ledgerTip: String?
    /// Last explicit ledger verification instant.
    private var verifiedAt: Date?

    /// Creates a pulse snapshot.
    /// - Parameter policyStore: Live policy store read on every snapshot, or
    ///   nil when the snapshot carries no policy posture.
    public init(policyStore: PolicyStore? = nil) {
        self.policyStore = policyStore
    }

    /// Records one sovereign verification ceremony. A ceremony missing either head is indeterminate
    /// and leaves the park untouched — missing material is not a failed check.
    public func recordSovereign(
        primaryTip: String?,
        sovereignTip: String?,
        checkpointVote: SovereignCheckpointVote? = nil,
        decision: SovereignDecision? = nil
    ) {
        let primary = HealthSnapshotValue.normalizedTip(primaryTip)
        let sovereign = HealthSnapshotValue.normalizedTip(sovereignTip)
        if let primary {
            ledgerTip = primary
        }
        let recordedAt = Date()
        guard let primary, let sovereign else {
            ceremony = SovereignCeremony(
                primaryTip: primary,
                sovereignTip: sovereign,
                vote: checkpointVote,
                matched: nil,
                decision: decision,
                recordedAt: recordedAt
            )
            return
        }
        var matched = primary == sovereign
        if let checkpointVote {
            matched = matched && checkpointVote.attests(tip: primary)
        }
        ceremony = SovereignCeremony(
            primaryTip: primary,
            sovereignTip: sovereign,
            vote: checkpointVote,
            matched: matched,
            decision: decision,
            recordedAt: recordedAt
        )
        parkedMismatch = !matched
    }

    /// Records one sovereign verification verdict. The verification instant stamps only on a
    /// passing verdict: advancing it on a mismatch would read as corroboration for history the
    /// ceremony just refused.
    public func recordSovereign(_ verdict: SovereignVerdict) {
        switch verdict.outcome {
        case .verified, .empty:
            recordSovereign(
                primaryTip: verdict.primaryTip,
                sovereignTip: verdict.sovereignTip,
                checkpointVote: nil,
                decision: verdict.decision
            )
            markVerifiedNow()
        case .mismatch:
            // Present the differing heads so the park latches, and never stamp the verification
            // instant for refused history.
            let sovereign = verdict.sovereignTip ?? verdict.checkpointTip
            guard sovereign != nil else {
                parkedMismatch = true
                return
            }
            recordSovereign(
                primaryTip: verdict.primaryTip,
                sovereignTip: sovereign,
                checkpointVote: nil,
                decision: verdict.decision
            )
        }
    }

    /// Records an unverifiable sovereign ceremony as a parked mismatch.
    public func recordSovereignFailure() {
        parkedMismatch = true
    }

    /// Records the live watchdog health into the pulse. Red parks fail-closed with the brake
    /// reason; green records quiet.
    public func recordWatchdogHealth(_ health: WatchdogHealth) {
        watchdogHealth = health
    }

    /// Records the gestation countdown for the info disclosure.
    ///
    /// - Parameter days: Remaining days 1...14, or nil when armed or braking.
    public func recordWatchdogGestation(_ days: Int?) {
        if let days {
            watchdogGestationDays = min(max(days, 1), 14)
        } else {
            watchdogGestationDays = nil
        }
    }

    /// Records subsystem probe completions, merging by verifier name.
    public func recordProbes(_ outcomes: [HealthProbeOutcome]) {
        for outcome in outcomes {
            guard !outcome.name.isEmpty else { continue }
            probes[outcome.name] = outcome
        }
    }

    /// Records one periodic security probe report into the pulse.
    public func recordProbes(_ report: ProbeReport) {
        guard !report.probes.isEmpty else {
            probes["suite"] = HealthProbeOutcome(
                name: "suite",
                passed: false,
                failClosed: true,
                detail: "Probe report carried no verifiers; rejected fail-closed."
            )
            return
        }
        recordProbes(report.probes)
    }

    /// Stamps an explicit ledger verification at this instant.
    public func markVerifiedNow() {
        verifiedAt = Date()
    }

    /// Builds the current verified snapshot value.
    public func snapshot() async -> HealthSnapshotValue {
        var reasons: [String] = []
        var notes: [String] = []
        var status = HealthPulseStatus.green
        if parkedMismatch {
            status = .red
            reasons.append(Self.sovereignParkedReason)
        }
        switch watchdogHealth {
        case .red:
            status = .red
            reasons.append(Self.watchdogBrakeReason)
        case .yellow:
            notes.append(Self.gestationNote(days: watchdogGestationDays ?? 14))
        case .green, nil:
            if let days = watchdogGestationDays {
                notes.append(Self.gestationNote(days: days))
            }
        }
        var policyHash: String?
        var policyVerified = false
        if let policyStore {
            let read = await policyStore.readSnapshot()
            if read.violations.isEmpty {
                policyVerified = true
                if let toml = try? PolicyStore.verifiedTOML(for: read.policy) {
                    policyHash = Self.sha256Hex(toml)
                }
            } else {
                status = .red
                reasons.append(contentsOf: read.violations)
            }
        }
        var failed = false
        var failedClosed = false
        // Sorted by name so reason order is deterministic across snapshots;
        // the served cap keeps the disclosure bounded either way.
        for probe in probes.values.sorted(by: { $0.name < $1.name }) where !probe.passed {
            failed = true
            if probe.failClosed {
                failedClosed = true
                status = .red
            } else if status == .green {
                status = .yellow
            }
            reasons.append(probe.detail ?? "Probe '\(probe.name)' failed.")
        }
        let verdict: HealthProbeVerdict? = if failedClosed {
            .fail
        } else if failed {
            .degraded
        } else if probes.isEmpty {
            nil
        } else {
            .pass
        }
        return HealthSnapshotValue(
            status: status,
            ledgerTip: ledgerTip,
            ledgerVerifiedAt: verifiedAt,
            policyHash: policyHash,
            policyVerified: policyVerified,
            probeVerdict: verdict,
            degradedReasons: HealthSnapshotValue.normalizedReasons(reasons),
            infoNotes: HealthSnapshotValue.normalizedInfoNotes(notes)
        )
    }

    /// SHA-256 hex digest following the repo-wide CryptoKit idiom.
    /// - Parameter text: Canonical bytes to digest.
    /// - Returns: Lowercase hex digest.
    private static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

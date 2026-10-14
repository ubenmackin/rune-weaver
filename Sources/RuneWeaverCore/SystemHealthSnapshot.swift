// Rune Weaver Core — Verified system-pulse health snapshot.
//
// Purpose: fuse subsystem probe completions, the live declarative policy
// posture, and sovereign ledger ceremonies into one closed green/yellow/red
// verdict with bounded disclosure-ready reasons behind `GET /health`.
// Scope: the pulse actor with its probe merge, sovereign latch, watchdog
// fusion, and live policy read. Probe execution and ceremony scheduling stay
// with the server.
// Architectural role: the system of record behind the health contract —
// recording only, never repairing, with red clearing on a fresh passing
// snapshot alone.

import CryptoKit
import Foundation

// MARK: - Pulse Status

/// Closed health verdict for the verified system pulse.
///
/// Green means every recorded verifier passes, yellow means degraded with
/// reasons behind a disclosure, and red means fail-closed and parked until
/// a fresh passing verification. Absence of a recorded failure is not a
/// failure: verifiers constrain the pulse only once they report, so the
/// served path records its probes before every snapshot.
public enum HealthPulseStatus: String, Sendable, Codable, Equatable {
    /// Every recorded verifier passes.
    case green
    /// Degraded with reasons behind a disclosure.
    case yellow
    /// Fail-closed, parked until a fresh passing verification.
    case red
}

/// Collapsed verdict over the recorded subsystem probes.
///
/// Nil when no probe has reported yet; otherwise pass means every recorded
/// probe passed, degraded means a non-critical probe failed, and fail means
/// a fail-closed probe failed.
public enum HealthProbeVerdict: String, Sendable, Codable, Equatable {
    /// Every recorded probe passed.
    case pass
    /// A non-critical probe failed.
    case degraded
    /// A fail-closed probe failed.
    case fail
}

// MARK: - Probe Outcomes

/// One subsystem probe completion recorded into the pulse.
///
/// A probe names a verifier the serving path actually ran (for example the
/// suite or traversal check). Search reachability is intentionally excluded;
/// it rides TopNav, never the pulse. A failed probe with
/// `failClosed` set forces the pulse red; any other failure degrades it to
/// yellow with the detail behind the disclosure.
public struct HealthProbeOutcome: Sendable, Equatable, Codable {
    /// Stable verifier name (for example `"suite"`).
    public let name: String
    /// Whether the probe passed.
    public let passed: Bool
    /// Whether a failure here fails closed instead of merely degrading.
    public let failClosed: Bool
    /// Bounded failure detail for the disclosure, nil when passing or silent.
    public let detail: String?

    /// Creates a probe outcome, normalizing the name and detail.
    /// - Parameters:
    ///   - name: Stable verifier name.
    ///   - passed: Whether the probe passed.
    ///   - failClosed: Whether a failure here fails closed.
    ///   - detail: Failure detail, blank degrading to nil.
    public init(name: String, passed: Bool, failClosed: Bool = false, detail: String? = nil) {
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.passed = passed
        self.failClosed = failClosed
        self.detail = HealthSnapshotValue.normalizedDetail(detail)
    }
}

// MARK: - Sovereign Ceremony

/// Enclave-signed checkpoint vote attesting a ledger head.
///
/// Carries the tip the enclave attests plus the signature and the signing
/// key identity. Validation here is structural only — present, agreeing
/// with the recorded head, and non-blank — because cryptographic
/// verification belongs to the enclave verifier producing the vote. This
/// recorder only judges whether the presented triple agrees.
public struct SovereignCheckpointVote: Sendable, Equatable, Codable {
    /// Ledger head the vote attests.
    public let tip: String
    /// Enclave signature bytes, hex encoded.
    public let signature: String
    /// Enclave signing key identity.
    public let signer: String

    /// Creates a checkpoint vote, trimming each field.
    /// - Parameters:
    ///   - tip: Ledger head the vote attests.
    ///   - signature: Enclave signature bytes, hex encoded.
    ///   - signer: Enclave signing key identity.
    public init(tip: String, signature: String, signer: String) {
        self.tip = tip.trimmingCharacters(in: .whitespacesAndNewlines)
        self.signature = signature.trimmingCharacters(in: .whitespacesAndNewlines)
        self.signer = signer.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether this vote attests the given normalized ledger head.
    /// - Parameter tip: Normalized head to check against.
    /// - Returns: True when the vote names that head with a non-blank
    ///   signature and signer.
    public func attests(tip: String) -> Bool {
        guard HealthSnapshotValue.normalizedTip(self.tip) == tip else { return false }
        return !signature.isEmpty && !signer.isEmpty
    }
}

/// One recorded sovereign verification ceremony.
///
/// Compares the primary ledger head against the sovereign copy head plus
/// the enclave-signed checkpoint vote. `matched` is nil when the ceremony
/// carried no comparable material — missing material is indeterminate, not
/// a failed check — and non-nil once both heads were present to compare.
/// `decision` preserves the ceremony's tiebreak naming which side the vote
/// attested, so a parked mismatch keeps its adjudication for the revert path.
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

    /// Creates a ceremony record.
    /// - Parameters:
    ///   - primaryTip: Observed primary ledger head.
    ///   - sovereignTip: Attested sovereign copy head.
    ///   - vote: Checkpoint vote presented with the ceremony.
    ///   - matched: Parity outcome.
    ///   - decision: How the signed vote resolved a disagreement.
    ///   - recordedAt: When the ceremony was recorded.
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
///
/// Bundles the closed status with the evidence behind it: the observed
/// ledger head and when it was last explicitly verified, the live policy
/// hash and whether the policy verifies, the collapsed probe verdict, and
/// the bounded reasons backing a non-green status.
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

    /// Creates a snapshot value.
    /// - Parameters:
    ///   - status: Closed pulse status.
    ///   - ledgerTip: Observed primary ledger head digest.
    ///   - ledgerVerifiedAt: Last explicit ledger verification instant.
    ///   - policyHash: SHA-256 of the canonical verified policy TOML.
    ///   - policyVerified: Whether the live policy verifies.
    ///   - probeVerdict: Collapsed probe verdict.
    ///   - degradedReasons: Backing reasons for a non-green status.
    ///   - infoNotes: Info notes that never move the dot.
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

    /// Normalizes a tip or hash digest: trims, lowercases, and accepts hex
    /// of up to `maxTipLength`. Blank, non-hex, or over-long input is
    /// rejected to nil instead of stored, so empty text never becomes a tip.
    /// - Parameter value: Raw digest candidate.
    /// - Returns: Normalized digest, or nil when rejected.
    public static func normalizedTip(_ value: String?) -> String? {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty, trimmed.count <= maxTipLength else { return nil }
        guard trimmed.allSatisfy(\.isHexDigit) else { return nil }
        return trimmed
    }

    /// Normalizes one reason fragment: trims and caps at `maxReasonLength`.
    /// Blank degrades to nil so empty text never becomes a reason.
    /// - Parameter value: Raw reason fragment.
    /// - Returns: Bounded reason, or nil when blank.
    public static func normalizedDetail(_ value: String?) -> String? {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maxReasonLength))
    }

    /// Normalizes a reason list: drops blanks, caps each entry, keeps the
    /// first `maxDegradedReasons` so the disclosure stays bounded.
    /// - Parameter values: Raw reasons.
    /// - Returns: Bounded reasons, empty when none survive.
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

    /// Normalizes a collapsed probe verdict against its closed vocabulary.
    /// Drifted values degrade to nil instead of failing the probe.
    /// - Parameter value: Raw verdict candidate.
    /// - Returns: Known verdict, or nil when blank or unknown.
    public static func normalizedProbeVerdict(_ value: String?) -> HealthProbeVerdict? {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return HealthProbeVerdict(rawValue: trimmed)
    }
}

// MARK: - Snapshot Actor

/// Actor-backed verified system-pulse snapshot.
///
/// Holds probe completions, the last sovereign ceremony, and the explicit
/// verification stamp, and fuses them with the live policy posture into one
/// closed verdict per `snapshot()`. Probe outcomes merge by name so
/// concurrent verifiers never clobber each other, while each verifier
/// refreshes its own entries — a recovered probe clears its failure on the
/// next passing cycle, but a parked sovereign mismatch clears only on a
/// freshly recorded passing ceremony, never on a probe result.
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

    /// Records one sovereign verification ceremony.
    ///
    /// A ceremony presenting both heads compares them, additionally
    /// requiring a presented vote to attest the recorded head; disagreement
    /// latches the pulse red, agreement records the baseline and clears a
    /// parked mismatch. A ceremony missing either head is indeterminate and
    /// leaves the park untouched — missing material is not a failed check.
    /// The observed primary head sticks even on an indeterminate ceremony,
    /// while blank tips never clear it.
    /// - Parameters:
    ///   - primaryTip: Observed primary ledger head.
    ///   - sovereignTip: Attested sovereign copy head.
    ///   - checkpointVote: Enclave-signed vote presented with the ceremony.
    ///   - decision: Tiebreak decision to preserve, nil when unadjudicated.
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

    /// Records one sovereign verification verdict.
    ///
    /// A passing verdict — `verified` or the explicit `empty` — records
    /// agreement and clears a parked mismatch; a `mismatch` verdict parks the
    /// pulse red until a fresh passing verdict arrives, even when the verdict
    /// carries no sovereign material to compare. A mismatch verdict
    /// always presents differing heads, because a chain hash covers every
    /// preceding entry, so a diverging copy or vote drifts its terminal tip;
    /// that head difference is exactly what parks the pulse. The verification
    /// instant stamps only on a passing verdict: advancing it on a mismatch
    /// would read as corroboration for history the ceremony just refused.
    /// The verdict's tiebreak decision is preserved on the recorded ceremony
    /// so an approved revert targets the attested side.
    /// - Parameter verdict: Ceremony verdict to record.
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
            // Present the differing heads so the park latches, and never
            // stamp the verification instant for refused history. A mismatch
            // without material still latches: no comparable heads is itself
            // a fail-closed refusal, not an indeterminate ceremony.
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
    ///
    /// A throwing ceremony — unreadable, forged, or stale checkpoint or copy —
    /// concludes nothing, so keeping the prior pulse would read a possibly
    /// green posture over refused material. Latching here keeps the fail-closed
    /// contract: stale past the bound fails and a mismatch parks red.
    public func recordSovereignFailure() {
        parkedMismatch = true
    }

    /// Records the live watchdog health into the pulse.
    ///
    /// Red parks fail-closed with the brake reason; green records quiet.
    /// Gestation never moves the dot: a gestating green carries its countdown
    /// through `recordWatchdogGestation(_:)` into info notes instead. Called on
    /// the serving cadence — every health probe and every periodic verifier
    /// run — so the pulse always fuses the latest brake posture.
    /// - Parameter health: Current watchdog health.
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
    ///
    /// Blank names are rejected. Replacing per name (instead of wholesale)
    /// keeps one verifier's cycle from clobbering another's, while a
    /// verifier's own newer outcome always supersedes its older one.
    /// - Parameter outcomes: Completed probe outcomes.
    public func recordProbes(_ outcomes: [HealthProbeOutcome]) {
        for outcome in outcomes {
            guard !outcome.name.isEmpty else { continue }
            probes[outcome.name] = outcome
        }
    }

    /// Records one periodic security probe report into the pulse.
    ///
    /// The suite runs on the periodic cadence — serve boot, policy writes,
    /// the nightly tick, and on-demand re-check applies — never per tool
    /// call, so each of its outcomes merges by verifier name exactly like
    /// the health route's own probe: a recovered verifier clears its
    /// failure on the next passing cycle, and the dashboard clears a red
    /// pulse only on that fresh passing snapshot, never on a timer. An
    /// empty report is rejected fail-closed: a report carrying no verifiers
    /// certifies nothing, so it records one fail-closed suite entry instead
    /// of letting a blank report pass as healthy.
    /// - Parameter report: Completed periodic probe report.
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
    ///
    /// Called when an explicit verification flow completes — never on a
    /// timer or a plain probe — so `ledgerVerifiedAt` proves a verification
    /// happened instead of merely echoing the last poll.
    public func markVerifiedNow() {
        verifiedAt = Date()
    }

    /// Builds the current verified snapshot value.
    ///
    /// Reads the live policy posture through the shared store, so policy
    /// writes surface here with no restart plus no watcher. Red wins over
    /// yellow: a parked mismatch, an engaged brake, live policy violations,
    /// or a failed fail-closed probe each fail closed, while any other probe
    /// failure merely degrades. Gestation plus idle search never move the dot:
    /// gestation countdown rides info notes while the status stays green.
    /// - Returns: The verified snapshot value.
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

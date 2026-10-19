// Rune Weaver Server — Health probe response contract for `GET /health`.

import Foundation
import RuneWeaverCore
import Vapor

/// Health probe response for `GET /health`. Carries the live Start stage when a SearXNG ensure
/// flight is running so the dashboard profile menu can poll one endpoint for both the dot and the
/// Starting line.
public struct HealthResponse: Content, Equatable {
    /// Closed verified-pulse status (`"green"`, `"yellow"`, or `"red"`). The route always serves
    /// the computed pulse status.
    public let status: String
    /// Engine display name.
    public let engine: String
    /// Engine API version.
    public let version: String
    /// Active serving model name.
    public let model: String?
    /// Active serving provider name.
    public let provider: String?
    /// Active context window limit.
    public let contextLength: Int?
    /// Whether the configured SearXNG URL answered (populated when known).
    public let searchReachable: Bool?
    /// Configured SearXNG base URL that was probed, when known.
    public let searchURL: String?
    /// Collapsed search status (`"running"`, `"stopped"`, or nil when unknown).
    public let searchStatus: String?
    /// In-flight Start stage (`resolving`, `daemon`, `pulling`, `starting`,
    /// `waiting`), nil when no Start is running.
    public let searchStage: String?
    /// Unix seconds when the in-flight Start began, nil when idle.
    /// A number (not a Date) so every dashboard decodes it without sharing a
    /// date strategy with the engine.
    public let searchStartedAt: Double?
    /// Live boot bind hostname from the serving context. Nil on payloads from
    /// engines that predate the boot-bind advertisement; the dashboard falls
    /// back to its pre-save file snapshot in that case.
    public let serverHostname: String?
    /// Live boot bind port from the serving context. Nil when unknown.
    public let serverPort: Int?
    /// Live boot allowed-hosts from the serving context. Nil when unknown.
    public let serverAllowedHosts: [String]?
    /// Observed primary ledger head digest from the last sovereign ceremony.
    /// Owner-private like the bind keys: omitted unless the caller cleared
    /// the owner gate, nil on payloads that predate the verified pulse.
    public let ledgerTip: String?
    /// Last explicit ledger verification as Unix seconds, mirroring
    /// `searchStartedAt` so dashboards decode it without sharing a date
    /// strategy. Nil until an explicit verification is stamped.
    public let ledgerVerifiedAt: Double?
    /// SHA-256 of the canonical verified policy TOML. Owner-private like the
    /// bind keys and the ledger tip; nil while the policy is unverified.
    public let policyHash: String?
    /// Whether the live policy verifies against the formal invariants.
    /// Nil on payloads from engines that predate the verified pulse.
    public let policyVerified: Bool?
    /// Collapsed probe verdict (`"pass"`, `"degraded"`, or `"fail"`).
    /// Nil before any probe reports or on pre-pulse payloads.
    public let probeVerdict: String?
    /// Bounded backing reasons for a non-green status, driving the
    /// dashboard disclosure. Nil when green or on pre-pulse payloads.
    public let degradedReasons: [String]?
    /// Bounded info notes that never move the dot, driving the dashboard
    /// Details disclosure alongside reasons. Nil when none or on pre-pulse payloads.
    public let infoNotes: [String]?
    /// Mapped recovery action for a red pulse.
    public let remediation: PulseRemediation

    /// Creates a health response.
    public init(
        status: String = "green",
        engine: String = "Rune Weaver",
        version: String = ServerPaths.apiVersion,
        model: String? = nil,
        provider: String? = nil,
        contextLength: Int? = nil,
        searchReachable: Bool? = nil,
        searchURL: String? = nil,
        searchStatus: String? = nil,
        searchStage: String? = nil,
        searchStartedAt: Double? = nil,
        serverHostname: String? = nil,
        serverPort: Int? = nil,
        serverAllowedHosts: [String]? = nil,
        ledgerTip: String? = nil,
        ledgerVerifiedAt: Double? = nil,
        policyHash: String? = nil,
        policyVerified: Bool? = nil,
        probeVerdict: String? = nil,
        degradedReasons: [String]? = nil,
        infoNotes: [String]? = nil,
        remediation: PulseRemediation = .none
    ) {
        self.status = Self.normalizedStatus(status)
        self.engine = engine
        self.version = version
        self.model = model
        self.provider = provider
        self.contextLength = contextLength
        self.searchReachable = searchReachable
        self.searchURL = searchURL
        self.searchStatus = searchStatus
        let trimmedStage = (searchStage ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.searchStage = trimmedStage.isEmpty ? nil : trimmedStage
        if let searchStartedAt, searchStartedAt.isFinite, searchStartedAt > 0 {
            self.searchStartedAt = searchStartedAt
        } else {
            self.searchStartedAt = nil
        }
        let trimmedHostname = (serverHostname ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.serverHostname = trimmedHostname.isEmpty ? nil : trimmedHostname
        if let serverPort, (1 ... 65535).contains(serverPort) {
            self.serverPort = serverPort
        } else {
            self.serverPort = nil
        }
        // Normalize through the shared Host form plus dedupe so the dashboard
        // restart banner compares pending file and boot snapshot under identical
        // semantics instead of tripping on casing or `:port` spellings.
        self.serverAllowedHosts = Self.normalizedAllowedHosts(serverAllowedHosts)
        // Tips normalize through the shared pulse bounds so an over-long or
        // non-hex digest degrades to absent instead of crossing the wire;
        // reasons drop blanks and cap count plus length for the disclosure.
        self.ledgerTip = HealthSnapshotValue.normalizedTip(ledgerTip)
        if let ledgerVerifiedAt, ledgerVerifiedAt.isFinite, ledgerVerifiedAt > 0 {
            self.ledgerVerifiedAt = ledgerVerifiedAt
        } else {
            self.ledgerVerifiedAt = nil
        }
        self.policyHash = HealthSnapshotValue.normalizedTip(policyHash)
        self.policyVerified = policyVerified
        self.probeVerdict = HealthSnapshotValue.normalizedProbeVerdict(probeVerdict)?.rawValue
        let reasons = HealthSnapshotValue.normalizedReasons(degradedReasons)
        self.degradedReasons = reasons.isEmpty ? nil : reasons
        let notes = HealthSnapshotValue.normalizedInfoNotes(infoNotes)
        self.infoNotes = notes.isEmpty ? nil : notes
        self.remediation = remediation
    }

    private enum CodingKeys: String, CodingKey {
        case status, engine, version, model, provider, contextLength
        case searchReachable, searchURL, searchStatus, searchStage, searchStartedAt
        case serverHostname, serverPort, serverAllowedHosts
        case ledgerTip, ledgerVerifiedAt, policyHash, policyVerified, probeVerdict, degradedReasons, infoNotes
        case remediation
    }

    /// Decodes tolerantly so payloads from engines that predate staged Start progress still parse
    /// with a nil stage instead of failing the probe.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try Self.normalizedStatus(container.decodeIfPresent(String.self, forKey: .status))
        engine = try container.decodeIfPresent(String.self, forKey: .engine) ?? "Rune Weaver"
        version = try container.decodeIfPresent(String.self, forKey: .version) ?? ServerPaths.apiVersion
        model = try container.decodeIfPresent(String.self, forKey: .model)
        provider = try container.decodeIfPresent(String.self, forKey: .provider)
        contextLength = try container.decodeIfPresent(Int.self, forKey: .contextLength)
        searchReachable = try container.decodeIfPresent(Bool.self, forKey: .searchReachable)
        searchURL = try container.decodeIfPresent(String.self, forKey: .searchURL)
        searchStatus = try container.decodeIfPresent(String.self, forKey: .searchStatus)
        let rawStage = try container.decodeIfPresent(String.self, forKey: .searchStage)
        let trimmedStage = (rawStage ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        searchStage = trimmedStage.isEmpty ? nil : trimmedStage
        let rawStartedAt = try container.decodeIfPresent(Double.self, forKey: .searchStartedAt)
        if let rawStartedAt, rawStartedAt.isFinite, rawStartedAt > 0 {
            searchStartedAt = rawStartedAt
        } else {
            searchStartedAt = nil
        }
        let rawHostname = try container.decodeIfPresent(String.self, forKey: .serverHostname)
        let trimmedHostname = (rawHostname ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        serverHostname = trimmedHostname.isEmpty ? nil : trimmedHostname
        let rawPort = try container.decodeIfPresent(Int.self, forKey: .serverPort)
        if let rawPort, (1 ... 65535).contains(rawPort) {
            serverPort = rawPort
        } else {
            serverPort = nil
        }
        let rawHosts = try container.decodeIfPresent([String].self, forKey: .serverAllowedHosts)
        serverAllowedHosts = Self.normalizedAllowedHosts(rawHosts)
        // Pulse keys normalize like the init so a hostile or unnormalized payload
        // with over-long digests or a reason flood degrades to the same
        // bounded shape the route serves instead of failing the probe.
        ledgerTip = try HealthSnapshotValue.normalizedTip(container.decodeIfPresent(String.self, forKey: .ledgerTip))
        let rawVerifiedAt = try container.decodeIfPresent(Double.self, forKey: .ledgerVerifiedAt)
        if let rawVerifiedAt, rawVerifiedAt.isFinite, rawVerifiedAt > 0 {
            ledgerVerifiedAt = rawVerifiedAt
        } else {
            ledgerVerifiedAt = nil
        }
        policyHash = try HealthSnapshotValue.normalizedTip(container.decodeIfPresent(String.self, forKey: .policyHash))
        policyVerified = try container.decodeIfPresent(Bool.self, forKey: .policyVerified)
        probeVerdict = try HealthSnapshotValue.normalizedProbeVerdict(container.decodeIfPresent(String.self, forKey: .probeVerdict))?.rawValue
        let rawReasons = try HealthSnapshotValue.normalizedReasons(container.decodeIfPresent([String].self, forKey: .degradedReasons))
        degradedReasons = rawReasons.isEmpty ? nil : rawReasons
        let rawNotes = try HealthSnapshotValue.normalizedInfoNotes(container.decodeIfPresent([String].self, forKey: .infoNotes))
        infoNotes = rawNotes.isEmpty ? nil : rawNotes
        let rawRemediation = try container.decodeIfPresent(String.self, forKey: .remediation)
        remediation = PulseRemediation(rawValue: rawRemediation ?? "") ?? .none
    }

    /// Normalizes a pulse status against its closed vocabulary.
    private static func normalizedStatus(_ value: String?) -> String {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch trimmed {
        case "green", "ok":
            return "green"
        case "red":
            return "red"
        case "yellow":
            return "yellow"
        default:
            return "yellow"
        }
    }

    /// Normalizes boot allowed-hosts through shared validation plus boot dedupe.
    private static func normalizedAllowedHosts(_ hosts: [String]?) -> [String]? {
        guard let hosts else { return nil }
        // Route through shared validation matching the Host gate so a widening
        // shape never widens the banner compare; invalid entries drop instead
        // of allowlisting a fragment.
        let valid = hosts.filter { (try? RuneWeaverConfig.validateAllowedHosts([$0])) != nil }
        return ServerEndpointConfig.dedupeNormalizedBootHosts(valid)
    }

    /// Encodes the stage keys only when a Start is in flight.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(status, forKey: .status)
        try container.encode(engine, forKey: .engine)
        try container.encode(version, forKey: .version)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encodeIfPresent(provider, forKey: .provider)
        try container.encodeIfPresent(contextLength, forKey: .contextLength)
        try container.encodeIfPresent(searchReachable, forKey: .searchReachable)
        try container.encodeIfPresent(searchURL, forKey: .searchURL)
        try container.encodeIfPresent(searchStatus, forKey: .searchStatus)
        try container.encodeIfPresent(searchStage, forKey: .searchStage)
        try container.encodeIfPresent(searchStartedAt, forKey: .searchStartedAt)
        try container.encodeIfPresent(serverHostname, forKey: .serverHostname)
        try container.encodeIfPresent(serverPort, forKey: .serverPort)
        try container.encodeIfPresent(serverAllowedHosts, forKey: .serverAllowedHosts)
        try container.encodeIfPresent(ledgerTip, forKey: .ledgerTip)
        try container.encodeIfPresent(ledgerVerifiedAt, forKey: .ledgerVerifiedAt)
        try container.encodeIfPresent(policyHash, forKey: .policyHash)
        try container.encodeIfPresent(policyVerified, forKey: .policyVerified)
        try container.encodeIfPresent(probeVerdict, forKey: .probeVerdict)
        try container.encodeIfPresent(degradedReasons, forKey: .degradedReasons)
        try container.encodeIfPresent(infoNotes, forKey: .infoNotes)
        try container.encode(remediation, forKey: .remediation)
    }
}

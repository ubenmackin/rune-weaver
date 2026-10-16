// Rune Weaver Core — Egress policy evaluator contract.

import Foundation

/// Typealias forwarding the host status enum from ``NetworkEgressPolicy``.
public typealias HostStatus = NetworkEgressPolicy.HostStatus

/// Evaluates outbound host access against network policies, session allowlists, and interactive triage grants.
public protocol EgressPolicyEvaluator: Sendable {
    /// Evaluates whether network egress to `host` is allowed, blocked, or unlisted.
    /// host: Destination hostname or IP address.
    func evaluateHostStatus(for host: String, sessionID: UUID?) async -> HostStatus
}

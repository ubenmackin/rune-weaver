// Rune Weaver Core — Egress policy evaluator contract.
//
// Purpose: gives the permission gate a narrow, injected question — is this host
// allowed, explicitly blocked, or unlisted — before it admits a host-bearing tool
// call, so explicitly blocked destinations are denied and unlisted ones park for
// owner approval without Core knowing how policy, session allowlists, or
// interactive triage grants are stored.
// Scope: one read-only evaluation method over a host plus optional session. Host
// extraction, policy storage, SSRF vetting, and credential injection stay with
// their owners; the Tools-layer `OutboundEgressSupervisor` is the production
// implementation and is injected after gate construction.
// Architectural role: dependency-inversion boundary between the permission gate
// and outbound egress supervision, keeping the gate's decision order fail-closed
// while the declarative policy remains the single authority on permitted egress.

import Foundation

/// Typealias forwarding the host status enum from ``NetworkEgressPolicy``.
public typealias HostStatus = NetworkEgressPolicy.HostStatus

/// Evaluates outbound host access against network policies, session allowlists, and interactive triage grants.
public protocol EgressPolicyEvaluator: Sendable {
    /// Evaluates whether network egress to `host` is allowed, blocked, or unlisted.
    /// - Parameters:
    ///   - host: Destination hostname or IP address.
    ///   - sessionID: The active conversation session identifier, if available.
    /// - Returns: ``HostStatus`` indicating `.allowed`, `.explicitlyBlocked(reason:)`, or `.unlisted(reason:)`.
    func evaluateHostStatus(for host: String, sessionID: UUID?) async -> HostStatus
}

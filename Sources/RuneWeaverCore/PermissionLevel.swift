// Rune Weaver Core — Graduated trust permission tiers for tool capabilities.
//
// Defines permission levels (readOnly, requiresApproval, trusted) evaluated
// by the permission gate to control unattended execution and user prompt gates.

/// Graduated trust level for a tool.
///
/// The permission gate reads this level to decide whether a tool call
/// needs explicit user approval or can run unattended.
public enum PermissionLevel: String, Sendable, Codable, Equatable, CaseIterable {
    /// Always allowed. Search, read, summarize. No approval needed.
    case readOnly
    /// Must be approved per-invocation by default, unless covered
    /// by a graduated-trust grant (5 min / 1 hour / 1 day / forever).
    case requiresApproval
    /// Auto-approved based on graduated trust policy.
    case trusted
}

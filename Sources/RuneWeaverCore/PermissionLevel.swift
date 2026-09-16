// Rune Weaver Core — Graduated trust permission tiers for tool capabilities.

/// Graduated trust level for a tool.
public enum PermissionLevel: String, Sendable, Codable, Equatable, CaseIterable {
    /// Always allowed. Search, read, summarize. No approval needed.
    case readOnly
    /// Must be approved per-invocation by default, unless covered
    /// by a graduated-trust grant (5 min / 1 hour / 1 day / forever).
    case requiresApproval
    /// Auto-approved based on graduated trust policy.
    case trusted
}

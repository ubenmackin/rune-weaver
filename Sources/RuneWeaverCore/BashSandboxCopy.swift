// Rune Weaver Core — Plain-language sandbox approval copy.

extension BashSandboxMode {
    /// Fallback tier when no narrower resolution applies.
    ///
    /// Single-sourced on the `[bash]` default so the fallback cannot drift
    /// from the configured default tier.
    public static var defaultMode: BashSandboxMode {
        BashConfig.defaultSandboxMode
    }
}

/// Single owner of plain-language sandbox approval copy.
public enum BashSandboxCopy: Sendable {
    /// Fixed summary for the resolved tier plus network flag.
    public static func approvalSummary(sandboxMode: BashSandboxMode, networkAllowed: Bool) -> String {
        switch sandboxMode {
        case .hostSeatbelt:
            // Host execution is user-scoped regardless of the network flag.
            return "Runs on your Mac as you with full access to your files."
        case .strictContainer:
            if networkAllowed {
                return "Runs in a temporary container with internet access to approved destinations only. Nothing is kept after the run."
            }
            return "Runs in a temporary container with no internet access. Nothing is kept after the run."
        case .machineScoped:
            if networkAllowed {
                return "Runs in a persistent workspace machine with internet access to approved destinations only. Workspace files persist across runs."
            }
            return "Runs in a persistent workspace machine with no internet access. Workspace files persist across runs."
        }
    }
}

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
        case .strictContainer, .machineScoped:
            if networkAllowed {
                return "Runs in an isolated virtual machine with internet access to approved destinations only."
            }
            return "Runs in an isolated virtual machine with no internet access."
        }
    }
}

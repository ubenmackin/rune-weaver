// Rune Weaver Tools — Regex defense-in-depth and network detection for sandboxed bash commands.

import Foundation
import RuneWeaverCore

/// Analyzes shell command strings for network activity and outbound targets.
public enum BashNetworkGuard: Sendable {
    /// Common network utilities and subcommands.
    private static let networkToolPatterns: [String] = [
        #"\bcurl\b"#,
        #"\bwget\b"#,
        #"\bgit\s+(clone|fetch|pull|push|submodule)\b"#,
        #"\b(npm|yarn|pnpm)\s+(install|i|add|update)\b"#,
        #"\bpip3?\s+install\b"#,
        #"\bcargo\s+install\b"#,
        #"\b(ssh|scp|sftp|nc|ncat|netcat|telnet|ping|ftp)\b"#
    ]

    /// Whether the command appears to invoke a network client.
    public static func requiresNetworkAccess(_ command: String) -> Bool {
        networkToolPatterns.contains { pattern in
            command.range(of: pattern, options: .regularExpression) != nil
        }
    }

    /// Extracts any explicit HTTP/HTTPS URLs present in the command string.
    ///
    /// Delegates to the approval queue's shared link scanner so bash
    /// screening and inbox triage cannot drift on detector shape.
    public static func extractURLs(from command: String) -> [String] {
        ApprovalQueue.extractLinkURLs(from: command)
    }
}

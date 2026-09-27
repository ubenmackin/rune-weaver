// Rune Weaver Tools — Security evaluation, chaining detection, and pattern matching for bash execution.

import Foundation
import RuneWeaverCore

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// Outcome of evaluating bash security policy for a command.
public struct BashDecision: Sendable, Equatable {
    /// Action to take: allow, ask, or deny.
    public let action: BashPermissionAction
    /// Whether chaining or command substitution was detected.
    public let isChained: Bool
    /// Human-readable explanation of why this action was decided.
    public let reason: String
    /// The rule pattern that matched, or nil if default action was used.
    public let matchedPattern: String?
    /// The canonical evaluated command string.
    public let command: String

    public var isAllowed: Bool {
        action == .allow
    }

    public var requiresApproval: Bool {
        action == .ask
    }

    public var isDenied: Bool {
        action == .deny
    }

    public init(
        action: BashPermissionAction,
        isChained: Bool,
        reason: String,
        matchedPattern: String?,
        command: String
    ) {
        self.action = action
        self.isChained = isChained
        self.reason = reason
        self.matchedPattern = matchedPattern
        self.command = command
    }
}

/// Security engine for bash command analysis, chaining detection, and permission rule evaluation.
public enum BashSecurity: Sendable {
    /// Detects whether a shell command contains chaining operators, command substitutions,
    /// or compound structures (e.g. `&&`, `||`, `;`, `|`, `&`, `\n`, `$(...)`, `` `...` ``, subshells).
    public static func detectChaining(in command: String) -> Bool {
        let chars = Array(command)
        var index = 0
        let count = chars.count
        var inSingleQuote = false
        var inDoubleQuote = false
        var escaped = false

        while index < count {
            let char = chars[index]
            if escaped {
                escaped = false
                index += 1
                continue
            }
            if char == "\\", !inSingleQuote {
                escaped = true
                index += 1
                continue
            }

            if char == "'", !inDoubleQuote {
                inSingleQuote.toggle()
                index += 1
                continue
            }

            if char == "\"", !inSingleQuote {
                inDoubleQuote.toggle()
                index += 1
                continue
            }

            if inSingleQuote {
                // Characters inside single quotes are strictly literal in bash
                index += 1
                continue
            }

            // Checks that apply inside double quotes or unquoted (evaluated by bash)
            if char == "`" {
                return true
            }
            if char == "$", index + 1 < count, chars[index + 1] == "(" {
                return true
            }

            // Checks that apply only when unquoted
            if !inDoubleQuote {
                if char.isNewline || char == ";" {
                    return true
                }
                if char == "|" {
                    return true // pipe or ||
                }
                if char == "&" {
                    // Check if part of redirection >& or <& (e.g. 2>&1)
                    let prevIsRedirect = index > 0 && (chars[index - 1] == ">" || chars[index - 1] == "<")
                    let nextIsAnd = index + 1 < count && chars[index + 1] == "&"
                    if nextIsAnd || !prevIsRedirect {
                        return true
                    }
                }
                if char == "(" || char == ")" {
                    return true // subshell or compound group
                }
            }

            index += 1
        }
        return false
    }

    /// Determines whether a shell command matches a rule pattern.
    ///
    /// Patterns support:
    /// - `*`: matches any command.
    /// - Wildcards (`*`, `?`): matched using standard fnmatch.
    /// - Command prefixes: e.g. `"echo"` matches `"echo"` and `"echo hello world"`.
    /// - Exact match: e.g. `"git status"` matches `"git status"` and `"git status --short"`.
    public static func matches(command: String, pattern: String) -> Bool {
        let trimmedCmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPat = pattern.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedPat == "*" {
            return true
        }

        // Handle fnmatch wildcards
        if trimmedPat.contains("*") || trimmedPat.contains("?") {
            #if canImport(Darwin) || canImport(Glibc)
                if fnmatch(trimmedPat, trimmedCmd, 0) == 0 {
                    return true
                }
            #endif

            // Convenience: if pattern is "echo *" also match exact "echo"
            if trimmedPat.hasSuffix(" *") {
                let prefix = String(trimmedPat.dropLast(2))
                if trimmedCmd == prefix {
                    return true
                }
            }
            return false
        }

        // Exact match
        if trimmedCmd == trimmedPat {
            return true
        }

        // Command prefix followed by space
        if trimmedCmd.hasPrefix(trimmedPat + " ") {
            return true
        }

        // Match first command token (binary name)
        let firstToken = trimmedCmd.split(separator: " ").first.map(String.init) ?? ""
        if firstToken == trimmedPat {
            return true
        }

        return false
    }

    /// Evaluates a bash command against security configuration and chaining rules.
    ///
    /// Rules:
    /// 1. If chaining is detected (`&&`, `||`, `;`, `|`, `&`, `\n`, `$()`, backticks):
    ///    Any rule that would evaluate to `allow` is **immediately demoted to `ask`**.
    ///    `deny` remains `deny`.
    /// 2. If single command: matches rules top to bottom, first match wins.
    /// 3. If no rule matches, falls back to `config.defaultAction`.
    public static func evaluate(command: String, config: BashConfig = BashConfig()) -> BashDecision {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return BashDecision(
                action: .deny,
                isChained: false,
                reason: "Command is empty.",
                matchedPattern: nil,
                command: trimmed
            )
        }

        let isChained = detectChaining(in: trimmed)

        // Find first matching rule
        let matchedRule = config.rules.first { matches(command: trimmed, pattern: $0.pattern) }

        let baseAction = matchedRule?.action ?? config.defaultAction

        if isChained {
            if baseAction == .allow {
                return BashDecision(
                    action: .ask,
                    isChained: true,
                    reason: "Chained or compound command detected; auto-approval demoted to 'ask' requiring manual confirmation.",
                    matchedPattern: matchedRule?.pattern,
                    command: trimmed
                )
            } else if baseAction == .deny {
                return BashDecision(
                    action: .deny,
                    isChained: true,
                    reason: "Command denied by policy pattern '\(matchedRule?.pattern ?? "deny")'.",
                    matchedPattern: matchedRule?.pattern,
                    command: trimmed
                )
            } else {
                return BashDecision(
                    action: .ask,
                    isChained: true,
                    reason: "Command requires manual confirmation (matches pattern '\(matchedRule?.pattern ?? "*")' and chained=true).",
                    matchedPattern: matchedRule?.pattern,
                    command: trimmed
                )
            }
        }

        let reason = if let pattern = matchedRule?.pattern {
            "Matched rule '\(pattern)' -> \(baseAction.rawValue)."
        } else {
            "No specific rule matched; using default action '\(baseAction.rawValue)'."
        }

        return BashDecision(
            action: baseAction,
            isChained: false,
            reason: reason,
            matchedPattern: matchedRule?.pattern,
            command: trimmed
        )
    }
}

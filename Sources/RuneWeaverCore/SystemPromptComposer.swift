import Foundation

/// Builds the default chat system prompt from the live tool registry.
///
/// The composer snapshots the registry via `ToolBus.availableTools()` at
/// session start so the model sees exactly the tools it can call: every
/// registered tool contributes its name, description, and input schema.
/// Identity, tool-use policy, and memory guidance are fixed text around
/// that live catalog. Callers keep the existing system-message plumbing
/// (`Orchestrator.systemPrompt`, `Message` role `.system`, and
/// `[Message].withSystemPrompt(_:)`); this type only produces the prompt
/// string and never touches message storage.
public enum SystemPromptComposer {
    /// Composes the default system prompt for the given tools.
    ///
    /// Tools render sorted by name so the prompt is deterministic across
    /// runs. Each tool contributes one entry with its name, description,
    /// and raw input schema so the agent can make proper calls. An empty
    /// registry still yields identity, policy, and memory guidance with
    /// a note that no tools are registered.
    /// - Parameter tools: Tools to catalog in the prompt.
    /// - Returns: Default system prompt text.
    public static func compose(tools: [any Tool]) -> String {
        let sorted = tools.sorted { $0.name < $1.name }
        var lines: [String] = []
        lines.append("You are Rune Weaver, a helpful personal assistant.")
        lines.append("")
        lines.append(
            "You help the user across mail, memory, files, and the web. "
                + "Be concise, accurate, and proactive within your permissions. "
                + "Use each tool's input schema to make proper calls."
        )
        lines.append("")
        lines.append("Available tools:")
        if sorted.isEmpty {
            lines.append("No tools are currently registered.")
        } else {
            for tool in sorted {
                lines.append("- \(tool.name): \(tool.description)")
                lines.append("  Input schema: \(tool.inputSchema.rawValue)")
                lines.append("  Permission: \(tool.permissionLevel.rawValue)")
            }
        }
        lines.append("")
        lines.append("Tool-use policy:")
        lines.append("- Read freely with read-only tools; searching and reading never need approval.")
        lines.append(
            "- Approval-gated writes go through the gate: requiresApproval tools run "
                + "only after the approval gate allows them; report denials plainly."
        )
        lines.append(
            "- Memory writes auto-allowed and auditable: remember_fact and recall_memories are trusted, "
                + "run without approval prompts, and every memory write is recorded in the audit log. "
                + "Never include secrets in prompts."
        )
        lines.append("")
        lines.append("Memory guidance:")
        lines.append(
            "- Call recall_memories before answering from history or when the user asks what you remember; "
                + "use the ranked memories as context and do not invent what recall does not support."
        )
        lines.append("- Call remember_fact unprompted for durable facts when the user states a lasting preference or fact, or asks you to remember something.")
        return lines.joined(separator: "\n")
    }

    /// Composes the default system prompt from the live tool registry.
    ///
    /// Snapshots the bus via `availableTools()` so the prompt always
    /// matches the session's registered plugins.
    /// - Parameter toolBus: Live registry owning the session's tools.
    /// - Returns: Default system prompt text.
    public static func compose(toolBus: ToolBus) async -> String {
        await compose(tools: toolBus.availableTools())
    }

    /// Resolves the effective system prompt, preserving the flag override.
    ///
    /// A non-empty `--system-prompt` value wins verbatim; a nil or empty
    /// flag falls back to the composed default. Empty mirrors
    /// `[Message].withSystemPrompt(_:)`, which treats empty prompts as
    /// absent, so the override contract never changes.
    /// - Parameters:
    ///   - flag: Explicit `--system-prompt` value, if any.
    ///   - tools: Tools to catalog when the flag is absent.
    /// - Returns: The flag when non-empty, else the composed prompt.
    public static func resolve(flag: String?, tools: [any Tool]) -> String {
        if let flag, !flag.isEmpty {
            return flag
        }
        return compose(tools: tools)
    }

    /// Resolves the effective system prompt from the live tool registry.
    ///
    /// A non-empty `--system-prompt` value wins verbatim without touching
    /// the bus; a nil or empty flag composes from `availableTools()`.
    /// - Parameters:
    ///   - flag: Explicit `--system-prompt` value, if any.
    ///   - toolBus: Live registry consulted when the flag is absent.
    /// - Returns: The flag when non-empty, else the composed prompt.
    public static func resolve(flag: String?, toolBus: ToolBus) async -> String {
        if let flag, !flag.isEmpty {
            return flag
        }
        return await compose(toolBus: toolBus)
    }
}

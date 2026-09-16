// Rune Weaver Core — Dynamic system prompt composition from the live tool registry.

import Foundation

/// Builds the default chat system prompt from the live tool registry.
public enum VisionSchemaFilter: Sendable {
    /// Screenshot-related schema keys hidden from text-only models.
    public static let screenshotKeys = [
        BrowserScreenshotPolicy.screenshotParamName,
        "screenshot",
        "include_screenshot"
    ]

    /// Removes the screenshot opt-in from a navigate schema.
    public static func strippedNavigateSchema(_ schema: JSONSchema) -> JSONSchema {
        guard let data = schema.rawValue.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data, options: []),
              var object = parsed as? [String: Any]
        else { return schema }
        if var properties = object["properties"] as? [String: Any] {
            for key in screenshotKeys {
                properties.removeValue(forKey: key)
            }
            object["properties"] = properties
        }
        if let required = object["required"] as? [String] {
            object["required"] = required.filter { !screenshotKeys.contains($0) }
        }
        if let anyOf = object["anyOf"] as? [[String: Any]] {
            object["anyOf"] = anyOf.filter { entry in
                guard let req = entry["required"] as? [String] else { return true }
                return !req.allSatisfy { screenshotKeys.contains($0) }
            }
        }
        guard let stripped = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let raw = String(data: stripped, encoding: .utf8)
        else { return schema }
        return JSONSchema(rawValue: raw)
    }

    /// Schema advertised for one tool given the model's vision capability.
    public static func displaySchema(for tool: any Tool, supportsVision: Bool) -> JSONSchema {
        guard !supportsVision, tool.name == BrowserScreenshotPolicy.navigateToolName else {
            return tool.inputSchema
        }
        return strippedNavigateSchema(tool.inputSchema)
    }
}

public enum SystemPromptComposer {
    /// Composes the default system prompt for the given tools.
    public static func compose(tools: [any Tool]) -> String {
        compose(tools: tools, supportsVision: true)
    }

    /// Composes the default system prompt honoring the model's vision capability.
    public static func compose(tools: [any Tool], supportsVision: Bool) -> String {
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
                lines.append("  Input schema: \(displaySchema(for: tool, supportsVision: supportsVision).rawValue)")
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
        if supportsVision {
            lines.append(
                "- browser.navigate screenshot opt-in: includeScreenshot defaults to false; "
                    + "set it true only when visual layout is needed. Captures are downscaled "
                    + "to 1280px JPEG under 500KB held in memory for the turn only "
                    + "(never written to disk), never persist to history, "
                    + "and audit stores the content hash only."
            )
        } else {
            lines.append(
                "- Screenshots are unavailable on this text-only model; do not request screenshots "
                    + "and ignore any screenshot parameter—text snapshots carry the page content."
            )
        }
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
    public static func compose(toolBus: ToolBus) async -> String {
        await compose(tools: toolBus.availableTools())
    }

    /// Composes the default system prompt from the live registry with vision awareness.
    public static func compose(toolBus: ToolBus, supportsVision: Bool) async -> String {
        await compose(tools: toolBus.availableTools(), supportsVision: supportsVision)
    }

    /// Resolves the effective system prompt, preserving the flag override.
    public static func resolve(flag: String?, tools: [any Tool]) -> String {
        resolve(flag: flag, tools: tools, supportsVision: true)
    }

    /// Resolves the effective prompt honoring the model's vision capability.
    public static func resolve(flag: String?, tools: [any Tool], supportsVision: Bool) -> String {
        if let flag, !flag.isEmpty {
            return flag
        }
        return compose(tools: tools, supportsVision: supportsVision)
    }

    /// Resolves the effective system prompt from the live tool registry.
    public static func resolve(flag: String?, toolBus: ToolBus) async -> String {
        await resolve(flag: flag, toolBus: toolBus, supportsVision: true)
    }

    /// Resolves the effective prompt from the live registry with vision awareness.
    public static func resolve(flag: String?, toolBus: ToolBus, supportsVision: Bool) async -> String {
        if let flag, !flag.isEmpty {
            return flag
        }
        return await compose(toolBus: toolBus, supportsVision: supportsVision)
    }

    /// Composes the system prompt customized for automated scheduled runs.
    public static func composeScheduled(tools: [any Tool]) -> String {
        composeScheduled(tools: tools, supportsVision: true)
    }

    /// Composes the scheduled prompt honoring the model's vision capability.
    public static func composeScheduled(tools: [any Tool], supportsVision: Bool) -> String {
        var base = compose(tools: tools, supportsVision: supportsVision)
        base += "\n\n"
        base += """
        Scheduled task guidance:
        - You are executing as an automated scheduled background task. There is no active human waiting in real time.
        - Persist critical run outcomes, updates, timestamps, or state changes into memory via remember_fact so subsequent runs or user chats can recall them.
        - Proactively query recall_memories to check prior run state, baselines, or preferences when relevant to the task.
        """
        return base
    }

    /// Composes the scheduled system prompt from the live tool registry.
    /// - Parameter toolBus: Live registry owning the session's tools.
    /// - Returns: Scheduled system prompt text.
    public static func composeScheduled(toolBus: ToolBus) async -> String {
        await composeScheduled(tools: toolBus.availableTools())
    }

    /// Composes the scheduled prompt from the live registry with vision awareness.
    public static func composeScheduled(toolBus: ToolBus, supportsVision: Bool) async -> String {
        await composeScheduled(tools: toolBus.availableTools(), supportsVision: supportsVision)
    }

    /// Schema advertised for one tool given the model's vision capability.
    public static func displaySchema(for tool: any Tool, supportsVision: Bool) -> JSONSchema {
        VisionSchemaFilter.displaySchema(for: tool, supportsVision: supportsVision)
    }

    /// Removes the screenshot opt-in from a navigate schema.
    public static func strippedNavigateSchema(_ schema: JSONSchema) -> JSONSchema {
        VisionSchemaFilter.strippedNavigateSchema(schema)
    }
}

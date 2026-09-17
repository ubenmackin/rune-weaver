// Rune Weaver Core — Dynamic system prompt composition from the live tool registry.

import Foundation

/// Validated tool set after prompt schema filtering.
/// Groups prompt-safe tools with skipped names so one corrupt plugin degrades to fewer entries.
public struct ValidatedTools: Sendable {
    /// Tools safe to advertise in prompts.
    public let valid: [any Tool]
    /// Names omitted for invalid schemas, carrying only names plus static reasons at call sites.
    public let skipped: [String]

    /// Creates a validated set.
    public init(valid: [any Tool], skipped: [String]) {
        self.valid = valid
        self.skipped = skipped
    }
}

/// One prompt-safe tool entry for system prompt rendering.
/// Exists as a struct because tuples beyond two members trip the tuple-size budget.
private struct PromptToolEntry: Sendable {
    /// Stable tool name.
    let name: String
    /// Human-readable summary.
    let description: String
    /// Advertised input schema.
    let schema: JSONSchema
    /// Trust level driving the compact permission marker.
    let permission: PermissionLevel
}

/// Per-tool byte contribution for prompt budget audits.
/// Tests alone consume this so production turns never pay logging overhead.
public struct PromptToolBytes: Sendable {
    /// Stable tool name in prompt order.
    public let name: String
    /// Compacted schema size in UTF-8 bytes.
    public let schemaBytes: Int
    /// Full two-line prompt entry size in UTF-8 bytes.
    public let entryBytes: Int
}

/// Total prompt size plus per-tool breakdown for budget decisions.
/// Tests alone consume this so production turns never pay logging overhead.
public struct PromptByteAudit: Sendable {
    /// Total prompt size in UTF-8 bytes.
    public let totalBytes: Int
    /// Per-tool entry sizes in prompt order.
    public let perTool: [PromptToolBytes]
}

/// Builds the default chat system prompt from the live tool registry.
public enum VisionSchemaFilter: Sendable {
    /// Screenshot-related schema keys hidden from text-only models.
    public static let screenshotKeys = [
        BrowserScreenshotPolicy.screenshotParamName,
        "screenshot",
        "include_screenshot"
    ]

    /// Checks whether a decoded schema object is safe to advertise in prompts or on the wire.
    /// Strict backends reject non-object types and malformed additionalProperties,
    /// so those shapes must be omitted rather than corrupting the prompt.
    public static func isValidParametersObject(_ object: [String: Any]) -> Bool {
        guard let type = object["type"] as? String, type == "object" else {
            return false
        }
        if let additional = object["additionalProperties"] {
            if additional is Bool {
                // Boolean form is the usual strict-mode contract.
            } else if additional is [String: Any] {
                // Dictionary form is a nested schema and remains encodable.
            } else {
                return false
            }
        }
        return true
    }

    /// Shared wording for unparseable schemas so prompt and wire logs agree.
    /// Carries only the tool name plus a static reason, never schema payloads.
    public static func unparseableSchemaMessage(for toolName: String) -> String {
        "Omitting tool '\(toolName)' with unparseable input schema for this turn"
    }

    /// Shared wording for invalid schemas so prompt and wire logs agree.
    /// Carries only the tool name plus a static reason, never schema payloads.
    public static func invalidSchemaMessage(for toolName: String) -> String {
        "Omitting tool '\(toolName)' with invalid input schema for this turn"
    }

    /// Partitions arbitrary entries into valid plus skipped names.
    /// Single-sources JSON parsing, the validity predicate, and log wording so
    /// prompt composition and wire builders withhold the same schemas with one message.
    /// - Parameters:
    ///   - entries: Candidates to partition.
    ///   - name: Stable tool name for logging and skip reporting.
    ///   - rawSchema: Raw JSON Schema document for parsing and validation.
    ///   - logSkips: Whether to log each skip; warning collectors pass false so
    ///     the prompt and wire filters remain the single logging sites per turn.
    /// - Returns: Valid entries plus skipped names in input order.
    public static func partitionValidSchemas<Entry>(
        entries: [Entry],
        name: (Entry) -> String,
        rawSchema: (Entry) -> String,
        logSkips: Bool = true
    ) -> (valid: [Entry], skipped: [String]) {
        var valid: [Entry] = []
        var skipped: [String] = []
        for entry in entries {
            let toolName = name(entry)
            guard let data = rawSchema(entry).data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data),
                  let object = parsed as? [String: Any]
            else {
                // Unparseable payloads would otherwise enter the prompt or wire verbatim.
                if logSkips {
                    RuneWeaverLog.tools.error("\(unparseableSchemaMessage(for: toolName))")
                }
                skipped.append(toolName)
                continue
            }
            guard isValidParametersObject(object) else {
                // Type and additionalProperties mismatches fail strict validation upstream.
                if logSkips {
                    RuneWeaverLog.tools.warning("\(invalidSchemaMessage(for: toolName))")
                }
                skipped.append(toolName)
                continue
            }
            valid.append(entry)
        }
        return (valid, skipped)
    }

    /// Partitions tools into prompt-safe entries plus skipped names.
    /// One corrupt plugin must not corrupt the whole prompt, so invalid entries
    /// are logged with their tool name and omitted while valid tools remain.
    public static func validatedTools(_ tools: [any Tool], logSkips: Bool = true) -> ValidatedTools {
        let part = partitionValidSchemas(
            entries: tools,
            name: { $0.name },
            rawSchema: { $0.inputSchema.rawValue },
            logSkips: logSkips
        )
        return ValidatedTools(valid: part.valid, skipped: part.skipped)
    }

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

    /// Validated schema advertised for one tool, or nil when the schema must be omitted.
    /// Returning nil keeps unparseable schemas out of the prompt while naming the skip.
    public static func validatedDisplaySchema(for tool: any Tool, supportsVision: Bool, logSkips: Bool = true) -> JSONSchema? {
        // Single-source validation through the shared partition so prompt and wire withhold
        // the same schemas with one wording; the partition logs the skip.
        let initial = partitionValidSchemas(
            entries: [tool],
            name: { $0.name },
            rawSchema: { $0.inputSchema.rawValue },
            logSkips: logSkips
        )
        guard initial.valid.first != nil else {
            return nil
        }
        guard !supportsVision, tool.name == BrowserScreenshotPolicy.navigateToolName else {
            return tool.inputSchema
        }
        let stripped = strippedNavigateSchema(tool.inputSchema)
        // Re-validate the stripped shape through the same partition so a transform that broke
        // validity withholds with the same wording instead of a second inline predicate.
        let rechecked = partitionValidSchemas(
            entries: [stripped.rawValue],
            name: { _ in tool.name },
            rawSchema: { $0 },
            logSkips: logSkips
        )
        guard !rechecked.valid.isEmpty else {
            return nil
        }
        return stripped
    }
}

public enum SystemPromptComposer {
    /// Composes the default system prompt for the given tools.
    public static func compose(tools: [any Tool]) -> String {
        compose(tools: tools, supportsVision: true)
    }

    /// Sorted prompt-safe entries shared by composition and auditing.
    /// Single-sourcing the sort plus schema filter keeps the live prompt and the
    /// budget audit identical when the entry format changes; callers choose the
    /// vision branch and whether skips log so audits stay silent.
    /// - Parameters:
    ///   - tools: Candidate tools in any order; sorting mirrors compose.
    ///   - supportsVision: Vision branch to filter.
    ///   - logSkips: Whether invalid schemas log; audits pass false.
    /// - Returns: Valid entries in prompt order.
    private static func sortedValidEntries(tools: [any Tool], supportsVision: Bool, logSkips: Bool) -> [PromptToolEntry] {
        // Omit invalid schemas so one bad plugin degrades to fewer prompt entries, not a corrupt prompt.
        let sorted = tools.sorted { $0.name < $1.name }
        var validEntries: [PromptToolEntry] = []
        validEntries.reserveCapacity(sorted.count)
        for tool in sorted {
            guard let schema = VisionSchemaFilter.validatedDisplaySchema(for: tool, supportsVision: supportsVision, logSkips: logSkips) else {
                continue
            }
            validEntries.append(PromptToolEntry(name: tool.name, description: tool.description, schema: schema, permission: tool.permissionLevel))
        }
        return validEntries
    }

    /// Composes the default system prompt honoring the model's vision capability.
    /// Disabled tools never reach the prompt because the ToolBus overloads snapshot
    /// availableTools, which already omits anything the operator turned off via ToolStateStore.
    public static func compose(tools: [any Tool], supportsVision: Bool) -> String {
        // Logging path: invalid schemas warn once here so operators see the skip.
        let validEntries = sortedValidEntries(tools: tools, supportsVision: supportsVision, logSkips: true)
        return renderPrompt(from: validEntries, supportsVision: supportsVision)
    }

    /// Renders the full prompt text from already-validated entries.
    /// Shared by composition and auditing so the measured bytes always match the
    /// live prompt; validation happens once in the caller, never inside the render.
    /// - Parameters:
    ///   - validEntries: Prompt-safe entries in prompt order.
    ///   - supportsVision: Vision branch to render.
    /// - Returns: Complete system prompt text.
    private static func renderPrompt(from validEntries: [PromptToolEntry], supportsVision: Bool) -> String {
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
        if validEntries.isEmpty {
            lines.append("No tools are currently registered.")
        } else {
            for entry in validEntries {
                lines.append(promptEntry(name: entry.name, description: entry.description, schema: entry.schema, permission: entry.permission))
            }
        }
        lines.append("")
        lines.append("Tool-use policy:")
        lines.append(
            "- Read freely with read-only tools; approval-gated writes go through the gate — "
                + "requiresApproval runs only after approval, trusted runs without prompts; report denials plainly."
        )
        // Prompt-level browser guardrail: tool descriptions compact to one line, so the
        // navigate auth/manifest sentence would otherwise never reach the model.
        lines.append(
            "- Auth walls escalate to human login; downloads are manifest-only; never invent credentials "
                + "or re-fetch with credentials."
        )
        lines.append(
            "- Memory writes auto-allowed and auditable: remember_fact and recall_memories are trusted "
                + "without prompts and every write is logged; never include secrets. "
                + "Call recall_memories before answering from history without inventing; "
                + "call remember_fact unprompted for durable facts."
        )
        if supportsVision {
            lines.append(
                "- browser.navigate screenshot opt-in: includeScreenshot defaults false; "
                    + "set true only when visual layout is needed "
                    + "(1280px JPEG under 500KB, turn-only, hash-only audit)."
            )
        } else {
            lines.append(
                "- Screenshots unavailable on this text-only model; do not request screenshots — "
                    + "text snapshots carry the page content."
            )
        }
        return lines.joined(separator: "\n")
    }

    /// Minifies a prompt schema to sorted-keys JSON without pretty whitespace.
    /// Strict backends still see a valid object because only whitespace and key order change.
    public static func compactSchemaJSON(_ schema: JSONSchema) -> String {
        guard let data = schema.rawValue.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: []),
              JSONSerialization.isValidJSONObject(object),
              let minified = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let raw = String(data: minified, encoding: .utf8)
        else { return schema.rawValue }
        return raw
    }

    /// Builds one two-line prompt entry shared by composition and auditing.
    /// Centralizing the headline plus compacted-schema shape keeps live prompts
    /// and budget measurements identical when the format changes.
    /// - Parameters:
    ///   - name: Stable tool name.
    ///   - description: Full description, compacted to one line inside.
    ///   - schema: Advertised input schema, minified inside.
    ///   - permission: Trust level driving the compact marker.
    /// - Returns: Two-line entry (headline plus indented input line).
    private static func promptEntry(name: String, description: String, schema: JSONSchema, permission: PermissionLevel) -> String {
        // Two lines per tool keep strict backends honest while dropping the
        // redundant readOnly marker: the default needs no label, only gated levels do.
        var headline = "- \(name): \(ToolPromptDisplay.oneLine(description))"
        if permission != .readOnly {
            headline += " [\(permission.rawValue)]"
        }
        return headline + "\n  Input: \(compactSchemaJSON(schema))"
    }

    /// Measures prompt budget without logging so tests alone decide what to print.
    /// Validates once silently then renders through the shared prompt builder,
    /// so the audit total and the live prompt cannot drift into separate shapes.
    /// - Parameters:
    ///   - tools: Candidate tools in any order; sorting mirrors compose.
    ///   - supportsVision: Vision branch to measure.
    /// - Returns: Total UTF-8 bytes plus per-tool schema and entry sizes in prompt order.
    public static func byteAudit(tools: [any Tool], supportsVision: Bool = true) -> PromptByteAudit {
        // Silent path: skips never log here, so audits stay quiet while compose above stays the single logging site.
        let validEntries = sortedValidEntries(tools: tools, supportsVision: supportsVision, logSkips: false)
        let prompt = renderPrompt(from: validEntries, supportsVision: supportsVision)
        var perTool: [PromptToolBytes] = []
        perTool.reserveCapacity(validEntries.count)
        for entry in validEntries {
            let compacted = compactSchemaJSON(entry.schema)
            let rendered = promptEntry(name: entry.name, description: entry.description, schema: entry.schema, permission: entry.permission)
            perTool.append(PromptToolBytes(
                name: entry.name,
                schemaBytes: compacted.utf8.count,
                entryBytes: rendered.utf8.count
            ))
        }
        return PromptByteAudit(totalBytes: prompt.utf8.count, perTool: perTool)
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

    /// Validated schema for one tool, or nil when the schema must be omitted from the prompt.
    public static func validatedDisplaySchema(for tool: any Tool, supportsVision: Bool, logSkips: Bool = true) -> JSONSchema? {
        VisionSchemaFilter.validatedDisplaySchema(for: tool, supportsVision: supportsVision, logSkips: logSkips)
    }

    /// Partitions tools into prompt-safe entries plus skipped names.
    public static func validatedTools(_ tools: [any Tool], logSkips: Bool = true) -> ValidatedTools {
        VisionSchemaFilter.validatedTools(tools, logSkips: logSkips)
    }

    /// Removes the screenshot opt-in from a navigate schema.
    public static func strippedNavigateSchema(_ schema: JSONSchema) -> JSONSchema {
        VisionSchemaFilter.strippedNavigateSchema(schema)
    }
}

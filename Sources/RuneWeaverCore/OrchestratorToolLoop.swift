// Rune Weaver Core — Shared tool-loop policy for turn orchestration.
// Holds the permission-partitioned narration fallback, degraded-tool warnings, and turn-budget
// helpers shared by the orchestrator and the CLI chat loop so both agree on one policy.

import Foundation

/// Resolves model-requested tool calls for the current context.
public typealias OrchestratorToolResolver = @Sendable ([Message], [any Tool]) async throws -> [ToolInput]

/// Single shared tool-loop policy for the orchestrator and the CLI chat loop.
public enum OrchestratorToolLoop {
    /// Returns the assistant content to persist for a tool round.
    public static func assistantNoteContent(text: String, calls: [ToolInput]) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return ToolInput.placeholderContent(for: calls)
        }
        if calls.isEmpty {
            return text
        }
        return text + "\n" + ToolInput.placeholderContent(for: calls)
    }

    /// Whether final assistant text is worth storing and returning.
    /// - Parameter text: Final assistant text.
    /// - Returns: True when the text is non-blank.
    public static func shouldStoreAssistantText(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether the tool-round budget is exceeded.
    public static func isLimitExceeded(rounds: Int, max: Int) -> Bool {
        rounds > max
    }

    /// Builds the compact episodic record for one tool execution.
    public static func episodicToolRecord(toolName: String, result: ToolResult) -> String? {
        MemoryEngine.episodicToolRecord(toolName: toolName, result: result)
    }

    /// Normalizes an input source label, defaulting blanks to `"chat"`.
    public static func resolvedSource(_ source: String) -> String {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "chat" : trimmed
    }

    /// Converts narrated placeholder lines into read-only tool calls.
    public static func narratedToolCalls(from text: String, tools: [any Tool]) -> [ToolInput] {
        narratedCalls(from: text, tools: tools, where: { $0.permissionLevel == .readOnly })
    }

    /// Converts narrated placeholder lines into approval-gated tool calls.
    public static func narratedGatedCalls(from text: String, tools: [any Tool]) -> [ToolInput] {
        narratedCalls(from: text, tools: tools, where: { $0.permissionLevel == .requiresApproval })
    }

    /// Converts narrated placeholder lines into tool calls matching a permission filter.
    private static func narratedCalls(
        from text: String,
        tools: [any Tool],
        where predicate: (any Tool) -> Bool
    ) -> [ToolInput] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        // Withhold invalid schemas fail-closed: narrated names for omitted tools never execute or file.
        // Silent partition keeps the prompt and wire filters as the single logging sites per turn.
        let validTools = VisionSchemaFilter.partitionValidSchemas(
            entries: tools,
            name: { $0.name },
            rawSchema: { $0.inputSchema.rawValue },
            logSkips: false
        ).valid
        let byName = Dictionary(validTools.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        // Single line-ending source keeps narration parsing identical to history
        // coverage, which folds the same shapes before matching plumbing lines.
        // A trailing newline is a terminator, not an extra blank line.
        var calls: [ToolInput] = []
        for rawLine in NormalizedText.splitLines(text) {
            guard let parsed = ToolInput.parsePlaceholderLine(rawLine) else { continue }
            guard let tool = byName[parsed.toolName] else { continue }
            guard predicate(tool) else { continue }
            guard isNarrationArgumentsJSON(parsed.argumentsJSON) else { continue }
            // Preserve the narrated identifier so the executed record collapses
            // with its persisted placeholder twin when grouping by call identity.
            // A blank identifier would collapse unrelated calls into one bucket,
            // so mint a fresh one there instead of reusing an empty key.
            let trimmedCallID = parsed.callID.trimmingCharacters(in: .whitespacesAndNewlines)
            let callID = trimmedCallID.isEmpty ? UUID().uuidString : trimmedCallID
            calls.append(ToolInput(
                toolName: parsed.toolName,
                argumentsJSON: parsed.argumentsJSON,
                callID: callID
            ))
        }
        return calls
    }

    /// Builds the parked-turn message ending a narration that needs approval.
    public static func waitingOnApprovalMessage(for calls: [ToolInput]) -> String {
        let names = Array(Set(calls.map(\.toolName))).sorted()
        let joined = names.isEmpty ? "the requested tool" : names.joined(separator: ", ")
        return "Waiting for approval to run \(joined). Approve in the approvals inbox to continue."
    }

    /// Builds the session notice recording a denied narrated approval.
    public static func deniedApprovalMessage(for toolName: String) -> String {
        let trimmed = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? "the requested tool" : trimmed
        return "Approval denied for \(name); not running it."
    }

    /// Builds the degraded-tool warning for one skipped tool name.
    /// - Parameter toolName: Tool omitted for this turn.
    /// - Returns: Warning carrying only the tool name plus a static reason.
    public static func degradedToolWarning(for toolName: String) -> String {
        let trimmed = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? "unknown tool" : trimmed
        return "Tool \(name) was disabled for this turn: invalid input schema"
    }

    /// Builds degraded-tool warnings for tools omitted by the resilient filter.
    /// - Parameter tools: Registered tools for this turn.
    /// - Returns: One warning per skipped tool, sorted for deterministic wire order.
    public static func degradedToolWarnings(for tools: [any Tool]) -> [String] {
        // Silent partition: the prompt and wire filters already log each skip,
        // so warning collection stays quiet to keep one log site per turn.
        let skipped = VisionSchemaFilter.partitionValidSchemas(
            entries: tools,
            name: { $0.name },
            rawSchema: { $0.inputSchema.rawValue },
            logSkips: false
        ).skipped
        return skipped.sorted().map { degradedToolWarning(for: $0) }
    }

    /// Whether raw narration arguments are a JSON object.
    private static func isNarrationArgumentsJSON(_ argumentsJSON: String) -> Bool {
        let trimmed = argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard let data = trimmed.data(using: .utf8) else { return false }
        do {
            let value = try JSONSerialization.jsonObject(with: data, options: [])
            return value is [String: Any]
        } catch {
            return false
        }
    }
}

// MARK: - NormalizedText line-ending fold lives in NormalizedText.swift

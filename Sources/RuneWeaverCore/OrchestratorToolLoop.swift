// Rune Weaver Core — Shared tool-loop policy for turn orchestration.
// Holds the permission-partitioned narration fallback, degraded-tool warnings, and turn-budget
// helpers shared by the orchestrator and the CLI chat loop so both agree on one policy.

import Foundation

/// Resolves model-requested tool calls for the current context.
public typealias OrchestratorToolResolver = @Sendable ([Message], [any Tool]) async throws -> [ToolInput]

/// Single shared tool-loop policy for the orchestrator and the CLI chat loop.
public enum OrchestratorToolLoop {
    /// Returns the assistant content to persist for a tool round.
    /// Narration already carries the model's own placeholder lines, so regenerating
    /// them would persist each call twice — the narration plus its generated twin.
    /// Only calls with no placeholder line yet get an appended line, and repeated
    /// call identifiers collapse so one call ID maps to one persisted line.
    public static func assistantNoteContent(text: String, calls: [ToolInput]) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let uniqueCalls = deduplicatedCalls(calls)
        if trimmed.isEmpty {
            return ToolInput.placeholderContent(for: uniqueCalls)
        }
        if uniqueCalls.isEmpty {
            return text
        }
        let narratedCallIDs = Set(
            NormalizedText.splitLines(text)
                .compactMap { ToolInput.parsePlaceholderLine($0)?.callID }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        )
        let pending = uniqueCalls.filter {
            !narratedCallIDs.contains($0.callID.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard !pending.isEmpty else { return text }
        return text + "\n" + ToolInput.placeholderContent(for: pending)
    }

    /// Collapses calls that share one call identifier, first occurrence winning.
    /// Duplicate identifiers would otherwise emit two wire calls answered by a
    /// single result, which strict OpenAI-compatible endpoints reject. Blank
    /// identifiers stay distinct because they cannot correlate to a result, so
    /// collapsing them would merge unrelated calls under one empty key.
    private static func deduplicatedCalls(_ calls: [ToolInput]) -> [ToolInput] {
        var seen = Set<String>()
        var unique: [ToolInput] = []
        for call in calls {
            let callID = call.callID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !callID.isEmpty else {
                unique.append(call)
                continue
            }
            guard seen.insert(callID).inserted else { continue }
            unique.append(call)
        }
        return unique
    }

    /// Whether one line is persisted tool-call plumbing.
    /// The parser trims each line itself, so raw lines stay on the same
    /// boundaries `NormalizedText.splitLines` already folded for narration.
    /// - Parameter line: One raw line from a persisted assistant note.
    /// - Returns: True when the line parses as a `Calling <tool> ... [<callID>]` placeholder.
    public static func isPlaceholderPlumbingLine(_ line: String) -> Bool {
        ToolInput.parsePlaceholderLine(line) != nil
    }

    /// Strips any `Calling <tool> ... [<callID>]` lines from text.
    /// Single source for history cleaning so episodic stripping and narration
    /// parsing cannot drift on what counts as plumbing.
    /// - Parameter text: Persisted assistant text, possibly carrying placeholders.
    /// - Returns: Remaining text, trimmed, with placeholder lines removed.
    public static func scrubPlaceholderPlumbing(from text: String) -> String {
        let cleanLines = NormalizedText.splitLines(text).filter { !isPlaceholderPlumbingLine($0) }
        return cleanLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// Longest retained slice of a user-supplied per-tool cancel reason.
    /// The reason is fed straight back into the model's tool history, so the cap
    /// bounds prompt growth and keeps a pasted wall of text from crowding the
    /// conversation context on the very next round.
    public static let maxToolCancelReasonLength = 500

    /// Trims and caps a per-tool cancel reason.
    /// - Parameter reason: Raw user reason, if any.
    /// - Returns: The retained reason, or nil when nothing usable remains so the
    ///   injected failure reads honestly as "no reason given" instead of trailing
    ///   whitespace or an empty suffix.
    public static func normalizedToolCancelReason(_ reason: String?) -> String? {
        let trimmed = (reason ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maxToolCancelReasonLength))
    }

    /// Builds the failure injected back to the model when a user cancels one call.
    /// The model reads this as the tool's own result, so it names the tool and its
    /// call identifier and states plainly that the user aborted it; that lets the
    /// loop re-scope and continue the turn instead of failing the whole request.
    /// - Parameters:
    ///   - toolName: Tool whose execution was aborted.
    ///   - callID: Correlation identifier the model used for the call.
    ///   - reason: Optional user reason, normalized here.
    /// - Returns: A failure result carrying the cancellation notice.
    public static func cancelledToolResult(toolName: String, callID: String, reason: String?) -> ToolResult {
        let detail = normalizedToolCancelReason(reason) ?? "no reason given"
        return .failure(
            toolCallID: callID,
            content: "Tool \(toolName) (\(callID)) cancelled by user: \(detail)",
            errorKind: .executionError
        )
    }

    /// Builds the compact episodic record for one tool execution.
    ///
    /// Fail-closed legacy path: provenance is unknown here, so the record
    /// labels as untrusted. Callers with a declared trust level use the
    /// overload below.
    public static func episodicToolRecord(toolName: String, result: ToolResult) -> String? {
        MemoryEngine.episodicToolRecord(toolName: toolName, result: result)
    }

    /// Builds the compact episodic record with declared provenance.
    ///
    /// Declaration-driven like the model-context path: untrusted outcomes wrap
    /// in the single-sourced labeled block while trusted outcomes keep the
    /// historical shape. The flag is the `[security] untrusted_labeling`
    /// off-switch plumbed from config for debugging.
    public static func episodicToolRecord(
        toolName: String,
        result: ToolResult,
        trustLevel: ContentTrustLevel,
        labelingEnabled: Bool = true
    ) -> String? {
        MemoryEngine.episodicToolRecord(
            toolName: toolName,
            result: result,
            trustLevel: trustLevel,
            labelingEnabled: labelingEnabled
        )
    }

    /// Builds the compact episodic record from the producing tool's declaration.
    ///
    /// Nil tools (unknown names) fail closed to untrusted: the bus usually
    /// answers those with engine-authored failures, but an unknown name
    /// carries no declaration to trust, so labeling keeps a future
    /// attacker-influenced failure from persisting as trusted history.
    public static func episodicToolRecord(
        toolName: String,
        result: ToolResult,
        for tool: (any Tool)?,
        labelingEnabled: Bool = true
    ) -> String? {
        guard let tool else {
            return MemoryEngine.episodicToolRecord(toolName: toolName, result: result)
        }
        return MemoryEngine.episodicToolRecord(
            toolName: toolName,
            result: result,
            trustLevel: tool.contentTrustLevel,
            labelingEnabled: labelingEnabled
        )
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
        if calls.contains(where: { $0.toolName == "engine.continue" }) {
            return "The agent has completed its allocated tool rounds. Awaiting continuation approval."
        }
        if calls.contains(where: { $0.toolName == "desktop.resume" }) {
            return "Desktop automation paused because you moved the mouse. Resume agent control to capture a fresh screenshot and continue."
        }
        let names = Array(Set(calls.map(\.toolName))).sorted()
        let joined = names.isEmpty ? "the requested tool" : names.joined(separator: ", ")
        return "Waiting for approval to run \(joined). Approve in the approvals inbox to continue."
    }

    /// Sentinel marking waiting-on-approval notes structurally so history filtering
    /// survives wording tweaks; content matching stays only for rows written before
    /// the marker existed.
    public static let waitingOnApprovalMarker = "waiting-on-approval"

    /// Builds a waiting-on-approval note carrying the structural marker.
    /// The marker rides in `toolCallID` so no persistence migration is needed:
    /// existing `tool_call_id` storage already round-trips it alongside content.
    public static func waitingNoteMessage(text: String) -> Message {
        Message(role: .assistant, content: text, toolCallID: waitingOnApprovalMarker)
    }

    /// Whether an assistant note matches the synthetic waiting-on-approval notice.
    /// Legacy content fallback for rows persisted before the structural marker.
    public static func isWaitingOnApprovalMessage(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "The agent has completed its allocated tool rounds. Awaiting continuation approval." {
            return true
        }
        if trimmed == "Desktop automation paused because you moved the mouse. Resume agent control to capture a fresh screenshot and continue." {
            return true
        }
        if trimmed.hasPrefix("Waiting for approval to run "),
           trimmed.hasSuffix(". Approve in the approvals inbox to continue.")
        {
            return true
        }
        return false
    }

    /// Whether a message is a waiting-on-approval notice, preferring the marker.
    /// Structural identity keeps provider sequencing stable when user-visible
    /// wording changes; content sniffing remains only for pre-marker history.
    public static func isWaitingOnApprovalMessage(_ message: Message) -> Bool {
        guard message.role == .assistant else { return false }
        if message.toolCallID == waitingOnApprovalMarker {
            return true
        }
        return isWaitingOnApprovalMessage(message.content)
    }

    /// Builds the session notice recording a denied narrated approval.
    public static func deniedApprovalMessage(for toolName: String) -> String {
        let trimmed = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "engine.continue" {
            return "Continuation stopped by user."
        }
        if trimmed == "desktop.resume" {
            return "Desktop automation stopped by operator."
        }
        if trimmed == "question.ask" {
            return "Question cancelled by operator. Do not proceed with this action."
        }
        let name = trimmed.isEmpty ? "the requested tool" : trimmed
        return "Approval denied for \(name); not running it."
    }

    /// Names of registered tools whose schema was omitted for this turn.
    /// Fail-closed denylist shared by the orchestrator and the CLI chat loop so a native
    /// or narrated call naming a degraded tool is withheld identically in both paths.
    /// Unknown or unregistered names stay absent, so they reach `ToolBus.execute` and the
    /// bus answers `invalid_tool` with available-tool names for model self-correction.
    /// - Parameter tools: Registered tools for this turn.
    /// - Returns: Skipped tool names as a set for O(1) membership tests.
    public static func degradedSchemaNames(for tools: [any Tool]) -> Set<String> {
        Set(VisionSchemaFilter.partitionValidSchemas(
            entries: tools,
            name: { $0.name },
            rawSchema: { $0.inputSchema.rawValue },
            logSkips: false
        ).skipped)
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
        degradedSchemaNames(for: tools).sorted().map { degradedToolWarning(for: $0) }
    }

    /// Returns the model-context content for one tool result, labeling untrusted output.
    ///
    /// Declaration-driven: the verdict comes from the tool's own
    /// `contentTrustLevel`, never from a name list, so a renamed tool keeps its
    /// provenance. Trusted results pass through byte-identical so local tools
    /// (files, memory, goals, media) pay zero diff; untrusted results wrap in the
    /// single-sourced labeled block. The flag is the `[security]
    /// untrusted_labeling` off-switch plumbed from config for debugging.
    /// - Parameters:
    ///   - content: Raw tool result content.
    ///   - trustLevel: Declared provenance of the producing tool.
    ///   - toolName: Declaring tool attributed on the opening delimiter.
    ///   - labelingEnabled: False bypasses labeling byte-identically for debugging.
    /// - Returns: Labeled content for untrusted tools, otherwise the input verbatim.
    public static func labeledResultContent(
        _ content: String,
        trustLevel: ContentTrustLevel,
        toolName: String,
        labelingEnabled: Bool = true
    ) -> String {
        guard labelingEnabled else { return content }
        guard trustLevel == .untrustedExternal else { return content }
        return ContentTrustLabeler.label(toolName: toolName, content: content)
    }

    /// Returns the model-context content for one tool's result.
    ///
    /// Nil tools (unknown or unregistered names) stay trusted and pass through:
    /// the bus already answers those with an `invalid_tool` failure whose text is
    /// engine-authored, not attacker-controlled, so wrapping it would only add
    /// noise.
    /// - Parameters:
    ///   - content: Raw tool result content.
    ///   - tool: Producing tool, or nil when unknown.
    ///   - labelingEnabled: False bypasses labeling byte-identically for debugging.
    /// - Returns: Labeled content for untrusted tools, otherwise the input verbatim.
    public static func labeledResultContent(
        _ content: String,
        for tool: (any Tool)?,
        labelingEnabled: Bool = true
    ) -> String {
        guard let tool else { return content }
        return labeledResultContent(content, trustLevel: tool.contentTrustLevel, toolName: tool.name, labelingEnabled: labelingEnabled)
    }

    /// Builds the `tool`-role message carrying one result into model context.
    ///
    /// Single-sourced composition point so the orchestrator, the parked resume
    /// path, and the CLI agree: untrusted payloads arrive delimited as data while
    /// trusted payloads keep their exact bytes. Role, call identifier, and error
    /// taxonomy ride through untouched so history reloads keep their badges.
    /// - Parameters:
    ///   - tool: Producing tool, or nil when unknown.
    ///   - result: Bus outcome to carry.
    ///   - labelingEnabled: False bypasses labeling byte-identically for debugging.
    /// - Returns: Tool message with labeled or verbatim content.
    public static func toolResultMessage(
        for tool: (any Tool)?,
        result: ToolResult,
        labelingEnabled: Bool = true
    ) -> Message {
        let content = labeledResultContent(result.content, for: tool, labelingEnabled: labelingEnabled)
        return Message(
            role: .tool,
            content: content,
            toolCallID: result.toolCallID,
            isError: result.isError,
            errorKind: result.errorKind,
            exitCode: result.exitCode
        )
    }

    /// Appends one labeled tool result for an already-resolved tool.
    /// Single-sources message composition with the lookup variant so parked
    /// calls holding their tool avoid a redundant registry round-trip.
    /// - Parameters:
    ///   - tool: Producing tool, or nil when unknown.
    ///   - result: Bus outcome to carry.
    ///   - conversations: Session owner receiving the message.
    ///   - sessionID: Session receiving the message.
    ///   - labelingEnabled: False bypasses labeling byte-identically for debugging.
    public static func appendLabeledResult(
        for tool: (any Tool)?,
        result: ToolResult,
        to conversations: ConversationManager,
        sessionID: UUID,
        labelingEnabled: Bool = true
    ) async {
        await conversations.append(
            toolResultMessage(for: tool, result: result, labelingEnabled: labelingEnabled),
            to: sessionID
        )
    }

    /// Appends one labeled tool result to its session in a single lookup.
    /// Single-sources the repeated `tool(named:)` plus
    /// `toolResultMessage(labelingEnabled:)` pair so the orchestrator, the
    /// parked resume path, and the CLI cannot drift on lookup versus labeling.
    /// Returns the producing tool so callers reuse it for the episodic record
    /// without a second lookup.
    /// - Parameters:
    ///   - bus: Registry owning the tool lookup.
    ///   - conversations: Session owner receiving the message.
    ///   - toolName: Tool that produced the result.
    ///   - result: Bus outcome to carry.
    ///   - sessionID: Session receiving the message.
    ///   - labelingEnabled: False bypasses labeling byte-identically for debugging.
    /// - Returns: Producing tool, or nil when unknown.
    @discardableResult
    public static func appendLabeledResult(
        on bus: ToolBus,
        to conversations: ConversationManager,
        toolName: String,
        result: ToolResult,
        sessionID: UUID,
        labelingEnabled: Bool = true
    ) async -> (any Tool)? {
        let tool = await bus.tool(named: toolName)
        await appendLabeledResult(for: tool, result: result, to: conversations, sessionID: sessionID, labelingEnabled: labelingEnabled)
        return tool
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
